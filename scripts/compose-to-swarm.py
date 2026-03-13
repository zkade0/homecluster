#!/usr/bin/env python3
import argparse
import copy
import re
import sys
from pathlib import Path

import yaml


DROP_SERVICE_KEYS = {
    "build",
    "container_name",
    "depends_on",
    "links",
    "profiles",
    "restart",
}


def slug(value: str) -> str:
    out = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip().lower()).strip("-")
    return out or "data"


def labels_to_dict(labels):
    if labels is None:
        return {}
    if isinstance(labels, dict):
        return {str(k): str(v) for k, v in labels.items()}
    out = {}
    if isinstance(labels, list):
        for item in labels:
            if isinstance(item, str) and "=" in item:
                k, v = item.split("=", 1)
                out[k] = v
    return out


def dict_to_labels(label_dict):
    return [f"{k}={v}" for k, v in sorted(label_dict.items())]


def parse_port_candidate(value: str):
    # examples: "8096:8096/tcp", "127.0.0.1:8080:80", "3000"
    raw = value
    if "/" in raw:
        raw = raw.split("/", 1)[0]
    parts = raw.split(":")
    if len(parts) == 1:
        candidate = parts[0]
    else:
        candidate = parts[-1]
    candidate = candidate.strip()
    if candidate.isdigit():
        return int(candidate)
    return None


def detect_service_port(service, explicit_port):
    if explicit_port:
        return explicit_port

    expose = service.get("expose")
    if isinstance(expose, list):
        for item in expose:
            if isinstance(item, int):
                return item
            if isinstance(item, str) and item.isdigit():
                return int(item)

    for entry in service.get("ports", []) or []:
        if isinstance(entry, str):
            val = parse_port_candidate(entry)
            if val:
                return val
        elif isinstance(entry, dict):
            target = entry.get("target")
            if isinstance(target, int):
                return target
            if isinstance(target, str) and target.isdigit():
                return int(target)

    return 80


def ensure_deploy_defaults(service):
    deploy = service.get("deploy")
    if not isinstance(deploy, dict):
        deploy = {}

    deploy.setdefault("mode", "replicated")
    if deploy.get("mode") == "replicated":
        deploy.setdefault("replicas", 1)

    placement = deploy.get("placement")
    if not isinstance(placement, dict):
        placement = {}
    constraints = placement.get("constraints")
    if not isinstance(constraints, list):
        constraints = []
    if "node.platform.os == linux" not in constraints:
        constraints.append("node.platform.os == linux")
    placement["constraints"] = constraints
    deploy["placement"] = placement

    restart_policy = deploy.get("restart_policy")
    if not isinstance(restart_policy, dict):
        restart_policy = {}
    restart_policy.setdefault("condition", "any")
    deploy["restart_policy"] = restart_policy

    update_config = deploy.get("update_config")
    if not isinstance(update_config, dict):
        update_config = {}
    update_config.setdefault("order", "stop-first")
    update_config.setdefault("parallelism", 1)
    deploy["update_config"] = update_config

    service["deploy"] = deploy


def ensure_timezone(service):
    env = service.get("environment")
    if env is None:
        service["environment"] = {"TZ": "${TIMEZONE}"}
        return

    if isinstance(env, dict):
        if "TZ" not in env:
            env["TZ"] = "${TIMEZONE}"
        service["environment"] = env
        return

    if isinstance(env, list):
        for item in env:
            if isinstance(item, str) and item.startswith("TZ="):
                return
        env.append("TZ=${TIMEZONE}")
        service["environment"] = env


def normalize_known_url_envs(service, hostname: str):
    env = service.get("environment")
    if env is None:
        return

    target_value = f"https://{hostname}"

    if isinstance(env, dict):
        if "JELLYFIN_PublishedServerUrl" in env:
            env["JELLYFIN_PublishedServerUrl"] = target_value
        service["environment"] = env
        return

    if isinstance(env, list):
        out = []
        replaced = False
        for item in env:
            if isinstance(item, str) and item.startswith("JELLYFIN_PublishedServerUrl="):
                out.append(f"JELLYFIN_PublishedServerUrl={target_value}")
                replaced = True
            else:
                out.append(item)
        if replaced:
            service["environment"] = out


def parse_string_volume(entry):
    parts = entry.split(":")
    if len(parts) == 1:
        return {"source": None, "target": parts[0], "mode": None, "type": "volume"}
    if len(parts) == 2:
        return {"source": parts[0], "target": parts[1], "mode": None, "type": "volume"}
    return {"source": parts[0], "target": parts[1], "mode": parts[2], "type": "volume"}


def is_absolute_path(value):
    if value is None:
        return False
    return value.startswith("/")


def is_placeholder_path(value):
    if not isinstance(value, str):
        return False
    return value == "/path" or value.startswith("/path/to/")


def is_external_volume(volumes_cfg, source_name):
    if not isinstance(volumes_cfg, dict):
        return False
    cfg = volumes_cfg.get(source_name)
    if not isinstance(cfg, dict):
        return False
    return bool(cfg.get("external"))


def convert_volumes(service_name, service, stack_name, output_volumes, input_volumes):
    mounts = service.get("volumes")
    if not isinstance(mounts, list):
        return

    converted = []
    anonymous_idx = 0

    for mount in mounts:
        parsed = None
        if isinstance(mount, str):
            parsed = parse_string_volume(mount)
        elif isinstance(mount, dict):
            parsed = {
                "type": mount.get("type", "volume"),
                "source": mount.get("source"),
                "target": mount.get("target"),
                "read_only": bool(mount.get("read_only", False)),
            }
        else:
            continue

        target = parsed.get("target")
        source = parsed.get("source")
        mtype = parsed.get("type", "volume")
        mode = parsed.get("mode")

        if not target:
            continue

        if (
            isinstance(mount, dict)
            and mtype == "bind"
            and source
            and is_absolute_path(source)
            and not is_placeholder_path(source)
        ):
            converted.append(mount)
            continue

        if source and isinstance(source, str) and source.startswith("${"):
            # Preserve env-driven source mounts as-is.
            converted.append(mount)
            continue

        if source and isinstance(source, str) and is_external_volume(input_volumes, source):
            converted.append(mount)
            continue

        needs_managed_volume = False
        if mtype == "bind":
            if not source or not is_absolute_path(source):
                needs_managed_volume = True
        elif mtype == "volume":
            needs_managed_volume = True

        if not needs_managed_volume:
            converted.append(mount)
            continue

        if source and isinstance(source, str):
            if source.startswith("./") or source.startswith("../"):
                name_seed = f"{service_name}-{Path(source).name or 'data'}"
            elif source.startswith("/"):
                name_seed = f"{service_name}-{Path(source).name or 'data'}"
            else:
                name_seed = source
        else:
            anonymous_idx += 1
            name_seed = f"{service_name}-{slug(target)}-{anonymous_idx}"

        vol_name = slug(name_seed).replace("-", "_")
        if not vol_name:
            vol_name = f"{service_name}_data"

        output_volumes.setdefault(
            vol_name,
            {
                "driver": "local",
                "driver_opts": {
                    "type": "none",
                    "o": "bind",
                    "device": f"/mnt/homelab-data/{stack_name}/{slug(vol_name)}",
                },
                "labels": {
                    "homelab.service": service_name,
                    "homelab.purpose": f"{slug(vol_name)}-data",
                    "homelab.path": target,
                },
            },
        )

        if isinstance(mount, dict):
            entry = {"type": "volume", "source": vol_name, "target": target}
            if parsed.get("read_only"):
                entry["read_only"] = True
            converted.append(entry)
        else:
            suffix = f":{mode}" if mode else ""
            converted.append(f"{vol_name}:{target}{suffix}")

    service["volumes"] = converted


def convert_secrets(input_secrets, warnings):
    if not isinstance(input_secrets, dict):
        return input_secrets

    out = {}
    for key, cfg in input_secrets.items():
        if isinstance(cfg, dict) and cfg.get("external"):
            out[key] = cfg
            continue

        secret_name = f"homelab_{slug(str(key)).replace('-', '_')}"
        out[key] = {"external": True, "name": secret_name}
        warnings.append(
            f"Secret '{key}' marked external as '{secret_name}'. Add it to SOPS and scripts/swarm-sync-secrets.sh."
        )
    return out


def ensure_edge_network(service):
    networks = service.get("networks")
    if networks is None:
        service["networks"] = ["edge"]
        return

    if isinstance(networks, list):
        if "edge" not in networks:
            networks.append("edge")
        service["networks"] = networks
        return

    if isinstance(networks, dict):
        networks.setdefault("edge", None)
        service["networks"] = networks


def set_traefik_labels(service, route_name, hostname, service_port):
    deploy = service.get("deploy")
    if not isinstance(deploy, dict):
        deploy = {}

    labels = labels_to_dict(deploy.get("labels"))
    middleware = f"{route_name}-https-redirect"
    labels.update(
        {
            "traefik.enable": "true",
            "traefik.swarm.network": "edge",
            f"traefik.http.routers.{route_name}.rule": f"Host(`{hostname}`)",
            f"traefik.http.routers.{route_name}.entrypoints": "web",
            f"traefik.http.routers.{route_name}.middlewares": middleware,
            f"traefik.http.middlewares.{middleware}.redirectscheme.scheme": "https",
            f"traefik.http.middlewares.{middleware}.redirectscheme.permanent": "true",
            f"traefik.http.routers.{route_name}-secure.rule": f"Host(`{hostname}`)",
            f"traefik.http.routers.{route_name}-secure.entrypoints": "websecure",
            f"traefik.http.routers.{route_name}-secure.tls": "true",
            f"traefik.http.routers.{route_name}-secure.service": route_name,
            f"traefik.http.services.{route_name}.loadbalancer.server.port": str(service_port),
        }
    )
    deploy["labels"] = dict_to_labels(labels)
    service["deploy"] = deploy


def normalize_networks(input_networks):
    out = {}
    if isinstance(input_networks, dict):
        for name, cfg in input_networks.items():
            if name == "edge":
                out[name] = {"external": True}
                continue
            if cfg is None:
                cfg = {}
            if isinstance(cfg, dict) and cfg.get("external"):
                out[name] = cfg
                continue

            cfg = cfg if isinstance(cfg, dict) else {}
            cfg.setdefault("driver", "overlay")
            cfg.setdefault("attachable", True)
            driver_opts = cfg.get("driver_opts")
            if not isinstance(driver_opts, dict):
                driver_opts = {}
            driver_opts.setdefault("encrypted", "true")
            cfg["driver_opts"] = driver_opts
            out[name] = cfg

    out.setdefault("edge", {"external": True})
    return out


def main():
    parser = argparse.ArgumentParser(description="Convert Docker Compose YAML to homelab Swarm stack YAML.")
    parser.add_argument("--input", required=True, help="Input Compose YAML file")
    parser.add_argument("--output", required=True, help="Output Swarm stack YAML file")
    parser.add_argument("--stack-name", required=True, help="Stack name")
    parser.add_argument("--hostname", required=True, help="Traefik hostname (e.g. app.${BASE_DOMAIN})")
    parser.add_argument("--route-service", default="", help="Service to route through Traefik (default: first service)")
    parser.add_argument("--service-port", type=int, default=0, help="Internal app port for Traefik")
    parser.add_argument(
        "--drop-route-service-ports",
        action="store_true",
        help="Remove published ports from the routed service (default behavior in wrapper script)",
    )
    args = parser.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output)

    if not in_path.exists():
        print(f"Input file not found: {in_path}", file=sys.stderr)
        return 1

    with in_path.open("r", encoding="utf-8") as f:
        src = yaml.safe_load(f) or {}

    services = src.get("services")
    if not isinstance(services, dict) or not services:
        print("Compose file has no services.", file=sys.stderr)
        return 1

    stack = {}
    output_services = {}
    output_volumes = {}
    warnings = []

    route_service = args.route_service or next(iter(services.keys()))
    if route_service not in services:
        print(f"Route service not found: {route_service}", file=sys.stderr)
        return 1

    for service_name, raw_service in services.items():
        service = copy.deepcopy(raw_service or {})

        for key in DROP_SERVICE_KEYS:
            service.pop(key, None)
        if str(service.get("user", "")).strip().lower() == "uid:gid":
            service.pop("user", None)

        if service_name == route_service:
            ensure_edge_network(service)
            service_port = detect_service_port(service, args.service_port)
            set_traefik_labels(service, args.stack_name, args.hostname, service_port)
            if args.drop_route_service_ports:
                service.pop("ports", None)
        else:
            # Never publish node ports by default for non-routed services.
            service.pop("ports", None)

        ensure_deploy_defaults(service)
        ensure_timezone(service)
        normalize_known_url_envs(service, args.hostname)
        convert_volumes(service_name, service, args.stack_name, output_volumes, src.get("volumes"))

        output_services[service_name] = service

    stack["services"] = output_services

    converted_secrets = convert_secrets(src.get("secrets"), warnings)
    if converted_secrets:
        stack["secrets"] = converted_secrets

    # Carry over non-external volumes, normalized to homelab bind path.
    input_volumes = src.get("volumes")
    if isinstance(input_volumes, dict):
        for name, cfg in input_volumes.items():
            if name in output_volumes:
                continue
            if isinstance(cfg, dict) and cfg.get("external"):
                output_volumes[name] = cfg

    if output_volumes:
        stack["volumes"] = output_volumes

    stack["networks"] = normalize_networks(src.get("networks"))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(stack, f, sort_keys=False, default_flow_style=False)

    for message in warnings:
        print(f"WARN: {message}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
