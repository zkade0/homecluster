# First-Try Checklist

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Documentation Index](INDEX.md) | [[docs/INDEX]]
- [NixOS Deploy](NIXOS-DEPLOY.md) | [[docs/NIXOS-DEPLOY]]
- [Secrets And SOPS](SECRETS-SOPS.md) | [[docs/SECRETS-SOPS]]

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
  - create from `swarm/env/cluster.env.example`; set non-sensitive defaults (for example `TIMEZONE`, `GRAFANA_ADMIN_USER`)
- `swarm/env/domain.txt` (gitignored)
  - create from `swarm/env/domain.txt.example`; set private base domain on the first non-comment line
- `swarm/env/cluster.env.local` (gitignored)
  - optional non-secret local overrides (non-domain values)
- `swarm/secrets/cluster-secrets.sops.yaml`
  - set encrypted values used by Swarm secrets (`ACME_EMAIL`, `CLOUDFLARE_API_TOKEN`, `GRAFANA_ADMIN_PASSWORD`, `VAULTWARDEN_ADMIN_TOKEN`, etc.)
  - for compose onboarding DNS automation, set `TECHNITIUM_API_TOKEN`
- `.sops.yaml`
  - set your real age recipient

## Required deployment sequence

1. `make nixos-bootstrap ...`
2. `make swarm-bootstrap`
3. `make swarm-sync-secrets`
4. `make swarm-deploy`

## Related

- [Architecture](ARCHITECTURE.md) | [[docs/ARCHITECTURE]]
- [Swarm Reconcile](SWARM-RECONCILE.md) | [[docs/SWARM-RECONCILE]]
- [Operations Notes](OPERATIONS.md) | [[docs/OPERATIONS]]
