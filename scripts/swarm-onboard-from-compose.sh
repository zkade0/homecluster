#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-}"
STACK_NAME="${STACK_NAME:-}"
STACK_FILE="${STACK_FILE:-}"
ROUTE_SERVICE="${ROUTE_SERVICE:-}"
SERVICE_PORT="${SERVICE_PORT:-}"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/swarm/env/cluster.env}"
ENV_LOCAL_FILE="${ENV_LOCAL_FILE:-${ENV_FILE}.local}"
DOMAIN_FILE="${DOMAIN_FILE:-${REPO_ROOT}/swarm/env/domain.txt}"
SOPS_SECRET_FILE="${SOPS_SECRET_FILE:-${REPO_ROOT}/swarm/secrets/cluster-secrets.sops.yaml}"

APP_HOST="${APP_HOST:-}"
APP_HOST_RESOLVED=""
TRAEFIK_VIP="${TRAEFIK_VIP:-192.168.8.11}"

DNS_UPSERT="${DNS_UPSERT:-1}"
DNS_TTL="${DNS_TTL:-300}"
DNS_RESOLVER_IP="${DNS_RESOLVER_IP:-192.168.8.10}"
TECHNITIUM_API_BASE="${TECHNITIUM_API_BASE:-}"
TECHNITIUM_ZONE="${TECHNITIUM_ZONE:-}"
TECHNITIUM_API_TOKEN="${TECHNITIUM_API_TOKEN:-}"
TECHNITIUM_API_TOKEN_FILE="${TECHNITIUM_API_TOKEN_FILE:-}"
TECHNITIUM_INSECURE_TLS="${TECHNITIUM_INSECURE_TLS:-1}"

DEPLOY="${DEPLOY:-1}"
DRY_RUN="${DRY_RUN:-0}"
PREFLIGHT="${PREFLIGHT:-1}"
PREFLIGHT_STRICT="${PREFLIGHT_STRICT:-1}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"
SYNC_SECRETS="${SYNC_SECRETS:-0}"
FORCE_REPLACE="${FORCE_REPLACE:-0}"
MANAGER_HOST="${MANAGER_HOST:-k8s-0}"
MANAGER_SSH="${MANAGER_SSH:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
ENSURE_BIND_DIRS="${ENSURE_BIND_DIRS:-1}"
ENSURE_BIND_DIRS_SCOPE="${ENSURE_BIND_DIRS_SCOPE:-manager}"
RENDERED_STACK=""

usage() {
  cat <<USAGE
Usage:
  COMPOSE_FILE=./jellyfin.yaml ./scripts/swarm-onboard-from-compose.sh

Env:
  COMPOSE_FILE=...                            # required
  STACK_NAME=<basename of compose file>
  STACK_FILE=swarm/stacks/<stack>.yaml
  ROUTE_SERVICE=<first service in compose>
  SERVICE_PORT=<auto-detect>
  APP_HOST=\${STACK_NAME}.\${BASE_DOMAIN}
  TRAEFIK_VIP=192.168.8.11

  ENV_FILE=swarm/env/cluster.env
  ENV_LOCAL_FILE=swarm/env/cluster.env.local
  DOMAIN_FILE=swarm/env/domain.txt
  SOPS_SECRET_FILE=swarm/secrets/cluster-secrets.sops.yaml

  DNS_UPSERT=1
  DNS_TTL=300
  DNS_RESOLVER_IP=192.168.8.10
  TECHNITIUM_API_BASE=http://dns.admin.\${BASE_DOMAIN}
  TECHNITIUM_ZONE=\${BASE_DOMAIN}
  TECHNITIUM_API_TOKEN=<optional; prefer SOPS>
  TECHNITIUM_API_TOKEN_FILE=<optional file path override>
  TECHNITIUM_INSECURE_TLS=1

  DEPLOY=1
  DRY_RUN=0
  PREFLIGHT=1
  PREFLIGHT_STRICT=1
  PREFLIGHT_ONLY=0
  SYNC_SECRETS=0
  FORCE_REPLACE=0
  MANAGER_HOST=k8s-0
  MANAGER_SSH=<optional override, e.g. root@192.168.8.5>
  SSH_KEY_FILE=<optional private key path>
  ENSURE_BIND_DIRS=1
  ENSURE_BIND_DIRS_SCOPE=manager|all
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$(sanitize_message "$*")"
}

err() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$(sanitize_message "$*")" >&2
}

sanitize_message() {
  local msg="$1"
  local value
  for value in "${TECHNITIUM_API_TOKEN:-}" "${TECHNITIUM_API_TOKEN_FILE:-}"; do
    if [[ -n "${value}" ]]; then
      msg="${msg//${value}/[REDACTED]}"
    fi
  done
  printf '%s' "${msg}"
}

cleanup() {
  if [[ -n "${RENDERED_STACK:-}" ]] && [[ -f "${RENDERED_STACK}" ]]; then
    rm -f "${RENDERED_STACK}"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    err "Missing required command: ${cmd}"
    exit 1
  }
}

ssh_cmd() {
  local target="$1"
  shift

  local -a args=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
  )

  if [[ -n "${SSH_KEY_FILE}" ]]; then
    args+=(
      -i "${SSH_KEY_FILE}"
      -o IdentitiesOnly=yes
      -o PreferredAuthentications=publickey
      -o PasswordAuthentication=no
    )
  fi

  ssh "${args[@]}" "${target}" "$@"
}

read_domain_file() {
  local domain_file="$1"
  awk 'NF && $1 !~ /^#/ {print $1; exit}' "${domain_file}" | tr -d '\r'
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    err "Env file not found: ${ENV_FILE}"
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  if [[ -f "${ENV_LOCAL_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_LOCAL_FILE}"
  fi
  set +a

  local domain_from_file=""
  if [[ -f "${DOMAIN_FILE}" ]]; then
    domain_from_file="$(read_domain_file "${DOMAIN_FILE}")"
    if [[ -z "${domain_from_file}" ]]; then
      err "DOMAIN_FILE is empty: ${DOMAIN_FILE}"
      exit 1
    fi
    export BASE_DOMAIN="${domain_from_file}"
  fi

  if [[ -z "${BASE_DOMAIN:-}" ]]; then
    err "BASE_DOMAIN is not set. Set DOMAIN_FILE (${DOMAIN_FILE}) or BASE_DOMAIN in env."
    exit 1
  fi
}

derive_names() {
  local compose_basename
  compose_basename="$(basename "${COMPOSE_FILE}")"

  if [[ -z "${STACK_NAME}" ]]; then
    STACK_NAME="${compose_basename%.*}"
  fi

  if [[ -z "${STACK_FILE}" ]]; then
    STACK_FILE="${REPO_ROOT}/swarm/stacks/${STACK_NAME}.yaml"
  elif [[ "${STACK_FILE}" != /* ]]; then
    STACK_FILE="${REPO_ROOT}/${STACK_FILE}"
  fi

  if [[ -z "${APP_HOST}" ]]; then
    APP_HOST="\${STACK_NAME}.\${BASE_DOMAIN}"
  fi

  if [[ -z "${TECHNITIUM_ZONE}" ]]; then
    TECHNITIUM_ZONE="${BASE_DOMAIN}"
  fi

  if [[ -z "${TECHNITIUM_API_BASE}" ]]; then
    TECHNITIUM_API_BASE="http://dns.admin.${BASE_DOMAIN}"
  fi

  APP_HOST_RESOLVED="${APP_HOST//\$\{STACK_NAME\}/${STACK_NAME}}"
  APP_HOST_RESOLVED="${APP_HOST_RESOLVED//\$STACK_NAME/${STACK_NAME}}"
  APP_HOST_RESOLVED="${APP_HOST_RESOLVED//\$\{BASE_DOMAIN\}/${BASE_DOMAIN}}"
  APP_HOST_RESOLVED="${APP_HOST_RESOLVED//\$BASE_DOMAIN/${BASE_DOMAIN}}"
}

resolve_manager_target() {
  if [[ -n "${MANAGER_SSH}" ]]; then
    echo "${MANAGER_SSH}"
    return 0
  fi

  require_cmd nix
  local ip user
  ip="$(nix --extra-experimental-features "nix-command flakes" eval --raw "path:${REPO_ROOT}/nixos#homelab.hosts.${MANAGER_HOST}.ip")"
  user="$(nix --extra-experimental-features "nix-command flakes" eval --raw "path:${REPO_ROOT}/nixos#homelab.hosts.${MANAGER_HOST}.user")"
  echo "${user}@${ip}"
}

collect_bind_dirs_from_rendered_stack() {
  python3 - "$1" <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    doc = yaml.safe_load(f) or {}

dirs = set()

for svc in (doc.get("services") or {}).values():
    for vol in (svc.get("volumes") or []):
        source = None
        if isinstance(vol, str):
            source = vol.split(":", 1)[0]
        elif isinstance(vol, dict):
            vtype = vol.get("type")
            src = vol.get("source")
            if vtype == "bind":
                source = src
        if source and isinstance(source, str) and source.startswith("/"):
            dirs.add(source)

for vol in (doc.get("volumes") or {}).values():
    if not isinstance(vol, dict):
        continue
    driver_opts = vol.get("driver_opts")
    if not isinstance(driver_opts, dict):
        continue
    if driver_opts.get("o") == "bind":
        device = driver_opts.get("device")
        if isinstance(device, str) and device.startswith("/"):
            dirs.add(device)

for item in sorted(dirs):
    print(item)
PY
}

ensure_bind_dirs_exist_on_all_nodes() {
  if [[ "${ENSURE_BIND_DIRS}" != "1" ]]; then
    log "ENSURE_BIND_DIRS=0, skipping bind directory creation."
    return 0
  fi

  local manager_target manager_user manager_ip
  manager_target="$(resolve_manager_target)"
  manager_user="${manager_target%@*}"
  manager_ip="${manager_target#*@}"

  mapfile -t bind_dirs < <(collect_bind_dirs_from_rendered_stack "${RENDERED_STACK}")
  if [[ "${#bind_dirs[@]}" -eq 0 ]]; then
    log "No absolute bind directories found in rendered stack."
    return 0
  fi

  local -a targets=()
  if [[ "${ENSURE_BIND_DIRS_SCOPE}" == "all" ]]; then
    mapfile -t node_ips < <(ssh_cmd "${manager_target}" "docker node ls -q | xargs -r docker node inspect --format '{{ .Status.Addr }}' | sort -u")
    if [[ "${#node_ips[@]}" -eq 0 ]]; then
      err "Could not discover Swarm node IPs from ${manager_target}"
      return 1
    fi
    local node_ip
    for node_ip in "${node_ips[@]}"; do
      targets+=("${manager_user}@${node_ip}")
    done
  else
    targets=("${manager_target}")
  fi

  local remote_target dir
  for remote_target in "${targets[@]}"; do
    for dir in "${bind_dirs[@]}"; do
      ssh_cmd "${remote_target}" "mkdir -p '${dir}'"
    done
  done

  log "Ensured bind directories exist: ${#bind_dirs[@]} paths on ${#targets[@]} target(s), scope=${ENSURE_BIND_DIRS_SCOPE}."
}

extract_technitium_token() {
  if [[ -n "${TECHNITIUM_API_TOKEN_FILE}" ]]; then
    if [[ ! -f "${TECHNITIUM_API_TOKEN_FILE}" ]]; then
      err "TECHNITIUM_API_TOKEN_FILE not found."
      return 1
    fi
    TECHNITIUM_API_TOKEN="$(tr -d '\r\n' < "${TECHNITIUM_API_TOKEN_FILE}")"
    return 0
  fi

  if [[ -n "${TECHNITIUM_API_TOKEN}" ]]; then
    return 0
  fi

  if ! command -v sops >/dev/null 2>&1; then
    return 0
  fi

  if [[ ! -f "${SOPS_SECRET_FILE}" ]]; then
    return 0
  fi

  TECHNITIUM_API_TOKEN="$(sops -d --extract '["stringData"]["TECHNITIUM_API_TOKEN"]' "${SOPS_SECRET_FILE}" 2>/dev/null || true)"
}

technitium_api_url() {
  local url="$1"

  if [[ "${TECHNITIUM_INSECURE_TLS}" == "1" ]]; then
    curl -fsS -K - <<EOF
insecure
url = "${url}"
EOF
    return 0
  fi

  curl -fsS -K - <<EOF
url = "${url}"
EOF
}

assert_dns_token_ready() {
  if [[ "${DNS_UPSERT}" != "1" ]]; then
    return 0
  fi
  if [[ -z "${TECHNITIUM_API_TOKEN}" ]]; then
    err "DNS_UPSERT=1 requires TECHNITIUM_API_TOKEN (token-only mode). Store TECHNITIUM_API_TOKEN in SOPS or set TECHNITIUM_API_TOKEN_FILE."
    return 1
  fi
}

dns_upsert_a_record() {
  local fqdn="$1"
  local ip="$2"

  local base add_url add_json status msg
  base="${TECHNITIUM_API_BASE%/}/api/zones/records"

  add_url="${base}/add?token=$(urlencode "${TECHNITIUM_API_TOKEN}")&domain=$(urlencode "${fqdn}")&zone=$(urlencode "${TECHNITIUM_ZONE}")&type=A&ipAddress=$(urlencode "${ip}")&ttl=$(urlencode "${DNS_TTL}")&overwrite=true"
  add_json="$(technitium_api_url "${add_url}" 2>&1 || true)"
  status="$(echo "${add_json}" | jq -r '.status // empty' 2>/dev/null || true)"

  if [[ "${status}" == "ok" ]]; then
    log "DNS upsert succeeded: ${fqdn} -> ${ip}"
    return 0
  fi

  msg="$(echo "${add_json}" | jq -r '.errorMessage // .message // empty' 2>/dev/null || true)"
  log "Technitium add record did not return ok (${msg:-unknown}), trying delete+add fallback."

  technitium_api_url "${base}/delete?token=$(urlencode "${TECHNITIUM_API_TOKEN}")&domain=$(urlencode "${fqdn}")&zone=$(urlencode "${TECHNITIUM_ZONE}")&type=A" >/dev/null 2>&1 || true

  add_url="${base}/add?token=$(urlencode "${TECHNITIUM_API_TOKEN}")&domain=$(urlencode "${fqdn}")&zone=$(urlencode "${TECHNITIUM_ZONE}")&type=A&ipAddress=$(urlencode "${ip}")&ttl=$(urlencode "${DNS_TTL}")"
  add_json="$(technitium_api_url "${add_url}")" || {
    err "DNS add failed for ${fqdn}"
    return 1
  }

  status="$(echo "${add_json}" | jq -r '.status // empty')"
  if [[ "${status}" != "ok" ]]; then
    err "DNS upsert failed for ${fqdn}: $(echo "${add_json}" | jq -r '.errorMessage // .message // "unknown error"')"
    return 1
  fi

  log "DNS upsert succeeded after fallback: ${fqdn} -> ${ip}"
}

validate_stack_render() {
  local rendered
  rendered="/tmp/${STACK_NAME}.rendered.yaml"
  RENDERED_STACK="${rendered}"

  export STACK_NAME
  export APP_HOST

  envsubst < "${STACK_FILE}" > "${rendered}"
  docker compose -f "${rendered}" config >/dev/null
  log "Rendered stack validated: ${rendered}"
}

check_unresolved_rendered_vars() {
  local unresolved
  unresolved="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${RENDERED_STACK}" | sort -u || true)"
  if [[ -n "${unresolved}" ]]; then
    err "Rendered stack still contains unresolved variables:"
    while IFS= read -r line; do
      err "  ${line}"
    done <<<"${unresolved}"
    return 1
  fi
  return 0
}

check_inline_sensitive_literals() {
  python3 - "${COMPOSE_FILE}" "${STACK_FILE}" "${RENDERED_STACK}" <<'PY'
import re
import sys
import yaml

SENSITIVE = re.compile(r"(PASSWORD|PASSWD|TOKEN|SECRET|API[_-]?KEY|PRIVATE[_-]?KEY|AUTH)", re.I)

def scan_env(env, file_name, service_name, issues):
    if isinstance(env, dict):
        items = env.items()
    elif isinstance(env, list):
        items = []
        for item in env:
            if isinstance(item, str) and "=" in item:
                k, v = item.split("=", 1)
                items.append((k, v))
    else:
        items = []

    for key, value in items:
        key = str(key)
        value = "" if value is None else str(value)
        if not SENSITIVE.search(key):
            continue
        if key.endswith("_FILE"):
            continue
        if value.startswith("${") or value == "":
            continue
        if value.startswith("/run/secrets/"):
            continue
        issues.append(f"{file_name}:{service_name}: inline sensitive literal in env '{key}'")

def scan(path, issues):
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    services = data.get("services") or {}
    if not isinstance(services, dict):
        return
    for svc_name, svc_cfg in services.items():
        if not isinstance(svc_cfg, dict):
            continue
        scan_env(svc_cfg.get("environment"), path, svc_name, issues)

issues = []
for p in sys.argv[1:]:
    scan(p, issues)

if issues:
    for i in sorted(set(issues)):
        print(i)
    sys.exit(1)
PY
}

check_external_secrets_exist() {
  local manager_target
  manager_target="$(resolve_manager_target)"
  mapfile -t external_secrets < <(python3 - "${RENDERED_STACK}" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

secrets = data.get("secrets") or {}
if isinstance(secrets, dict):
    for key, cfg in secrets.items():
        if not isinstance(cfg, dict):
            continue
        if cfg.get("external"):
            name = cfg.get("name") or key
            print(name)
PY
)

  if [[ "${#external_secrets[@]}" -eq 0 ]]; then
    return 0
  fi

  local missing=0
  local secret_name
  for secret_name in "${external_secrets[@]}"; do
    if ! ssh_cmd "${manager_target}" "docker secret inspect '${secret_name}' >/dev/null 2>&1"; then
      err "Missing external Swarm secret: ${secret_name}"
      missing=1
    fi
  done
  if [[ "${missing}" -eq 1 ]]; then
    err "Add missing secrets to SOPS + scripts/swarm-sync-secrets.sh, then run make swarm-sync-secrets."
    return 1
  fi
  return 0
}

run_preflight() {
  if [[ "${PREFLIGHT}" != "1" ]]; then
    log "PREFLIGHT=0, skipping preflight checks."
    return 0
  fi

  local failures=0

  if ! check_unresolved_rendered_vars; then
    failures=1
  fi

  if ! check_inline_sensitive_literals; then
    err "Inline secrets detected. Move values to Swarm secrets/SOPS and reference via *_FILE or /run/secrets mounts."
    failures=1
  fi

  if [[ "${PREFLIGHT_STRICT}" == "1" ]] && [[ "${DEPLOY}" == "1" ]]; then
    if ! check_external_secrets_exist; then
      failures=1
    fi
  fi

  if [[ "${failures}" -ne 0 ]]; then
    err "Preflight failed."
    return 1
  fi
  log "Preflight checks passed."
  return 0
}

convert_stack() {
  local -a args=(
    --input "${COMPOSE_FILE}"
    --output "${STACK_FILE}"
    --stack-name "${STACK_NAME}"
    --hostname "${APP_HOST}"
    --drop-route-service-ports
  )

  if [[ -n "${ROUTE_SERVICE}" ]]; then
    args+=(--route-service "${ROUTE_SERVICE}")
  fi
  if [[ -n "${SERVICE_PORT}" ]]; then
    args+=(--service-port "${SERVICE_PORT}")
  fi

  python3 "${REPO_ROOT}/scripts/compose-to-swarm.py" "${args[@]}"
  log "Converted ${COMPOSE_FILE} -> ${STACK_FILE}"
}

verify_dns() {
  if ! command -v nslookup >/dev/null 2>&1; then
    return 0
  fi

  log "DNS lookup via ${DNS_RESOLVER_IP}:"
  nslookup "${APP_HOST_RESOLVED}" "${DNS_RESOLVER_IP}" || true
}

deploy_stack() {
  if [[ "${DEPLOY}" != "1" ]]; then
    log "DEPLOY=0, skipping deploy."
    return 0
  fi

  local -a make_args=(
    swarm-reconcile
    "STACK_FILE=${STACK_FILE}"
    "SYNC_SECRETS=${SYNC_SECRETS}"
    "FORCE_REPLACE=${FORCE_REPLACE}"
    "MANAGER_HOST=${MANAGER_HOST}"
  )

  if [[ -n "${MANAGER_SSH}" ]]; then
    make_args+=("MANAGER_SSH=${MANAGER_SSH}")
  fi
  if [[ -n "${SSH_KEY_FILE}" ]]; then
    make_args+=("SSH_KEY_FILE=${SSH_KEY_FILE}")
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    make_args+=("DRY_RUN=1")
  fi

  log "Running: make ${make_args[*]}"
  (cd "${REPO_ROOT}" && make "${make_args[@]}")
}

main() {
  trap cleanup EXIT

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ -z "${COMPOSE_FILE}" ]]; then
    err "COMPOSE_FILE is required."
    usage
    exit 1
  fi

  if [[ "${COMPOSE_FILE}" != /* ]]; then
    COMPOSE_FILE="${REPO_ROOT}/${COMPOSE_FILE}"
  fi

  require_cmd python3
  require_cmd docker
  require_cmd envsubst
  require_cmd curl
  require_cmd jq

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    err "Compose file not found: ${COMPOSE_FILE}"
    exit 1
  fi

  load_env
  derive_names
  extract_technitium_token

  log "Stack name: ${STACK_NAME}"
  log "App host template: ${APP_HOST}"
  log "App host resolved: ${APP_HOST_RESOLVED}"
  log "Output stack: ${STACK_FILE}"

  convert_stack
  validate_stack_render
  run_preflight

  if [[ "${PREFLIGHT_ONLY}" == "1" ]]; then
    log "PREFLIGHT_ONLY=1, skipping DNS/deploy."
    return 0
  fi

  if [[ "${DEPLOY}" == "1" ]]; then
    ensure_bind_dirs_exist_on_all_nodes
  fi

  if [[ "${DNS_UPSERT}" == "1" ]]; then
    assert_dns_token_ready
    dns_upsert_a_record "${APP_HOST_RESOLVED}" "${TRAEFIK_VIP}"
    verify_dns
  else
    log "DNS_UPSERT=0, skipping DNS automation."
  fi

  deploy_stack

  log "Done."
  log "Open: https://${APP_HOST_RESOLVED}"
}

main "$@"
