# First-Try Checklist

Fill these before first Swarm bootstrap to maximize success.

## Required from you

- Confirm these IPs are free/reserved:
  - `192.168.8.5` (`k8s-0`)
  - `192.168.8.6` (`k8s-1`)
  - `192.168.8.7` (`k8s-2`)
- Cloudflare API token with `Zone DNS Edit` + `Zone Read`.
- Verify node primary NIC names.
- Confirm LAN gateway (default scripts assume `192.168.8.1`).
- Router forwarding for WAN `443` to your homelab ingress node(s) as needed.

## Required local edits

- `swarm/env/cluster.env`
  - set `BASE_DOMAIN` and `TIMEZONE`
- `swarm/secrets/cluster-secrets.sops.yaml`
  - set encrypted values used by Swarm secrets (`ACME_EMAIL`, `CLOUDFLARE_API_TOKEN`, `VAULTWARDEN_ADMIN_TOKEN`, etc.)
- `.sops.yaml`
  - set your real age recipient

## Required deployment sequence

1. `make nixos-bootstrap ...`
2. `make swarm-bootstrap`
3. `make swarm-sync-secrets`
4. `make swarm-deploy`
