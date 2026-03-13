# Docker Swarm Layout

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Documentation Index](../docs/INDEX.md) | [[docs/INDEX]]
- [Swarm Reconcile](../docs/SWARM-RECONCILE.md) | [[docs/SWARM-RECONCILE]]
- [Compose Onboarding](../docs/STACK-FROM-COMPOSE.md) | [[docs/STACK-FROM-COMPOSE]]

This directory is the active Layer 2 deployment path for homelab services.

## Files

- `env/cluster.env.example`: tracked env template
- `env/cluster.env`: local env file (gitignored)
- `env/cluster.env.local`: local override env file (gitignored)
- `env/domain.txt.example`: tracked domain template
- `env/domain.txt`: local base domain file (gitignored)
- `secrets/cluster-secrets.sops.yaml`: encrypted secret source for Swarm
- `stacks/homelab.yaml`: main Swarm stack
- `stacks/monitoring.yaml`: Prometheus + Grafana stack for split-stack deployments
- `stacks/local-dns.yaml`: Technitium DNS stack (single replica, not hostname-pinned)
- `stacks/speedtest.yaml`: LibreSpeed Rust stack (single replica behind Traefik)
- `stacks/uptime-kuma.yaml`: Uptime Kuma stack (single replica with persistent SQLite data)
- `stacks/backups.yaml`: Restic backup stack (single replica failover + NFS repository target)

## Deploy order

1. Build/deploy NixOS nodes.
2. Bootstrap Swarm membership:

```bash
make swarm-bootstrap
```

3. Create/update Swarm secrets from SOPS:

```bash
make swarm-sync-secrets
```

4. Deploy the stack:

```bash
make swarm-deploy
```

Or run the manual reconcile pipeline for split stacks:

```bash
make swarm-reconcile SSH_KEY_FILE=~/.ssh/homelab-nixos-admin MANAGER_SSH=root@192.168.8.5
```

For onboarding a new app from Docker Compose (auto-convert + DNS upsert + reconcile):

```bash
make swarm-onboard-from-compose COMPOSE_FILE=./jellyfin.yaml
```

Details: `docs/SWARM-RECONCILE.md`
Reference docs:
- `docs/SERVICE-CATALOG.md`
- `docs/BACKUP-RESTORE.md`
- `docs/SECRETS-SOPS.md`
- `docs/STACK-FROM-COMPOSE.md`

## Domain setup

Create your local domain file:

```bash
cp swarm/env/domain.txt.example swarm/env/domain.txt
```

Put your private base domain on the first non-comment line of `swarm/env/domain.txt`.

## Optional: local DNS (Technitium)

Set `TECHNITIUM_ADMIN_PASSWORD` in `swarm/secrets/cluster-secrets.sops.yaml`, sync secrets, then deploy:

```bash
make swarm-sync-secrets
make swarm-deploy-technitium-dns
```

Recommended LAN client DNS behavior:
- Hand out `192.168.8.10` (keepalived VIP) as DHCP DNS so clients query Technitium directly.
- Do not set a public secondary DNS (for example `1.1.1.1`) if you want full per-client visibility/filtering in Technitium.
- Technitium DNS is exposed on `53/tcp` and `53/udp` in host publish mode (preserves real client source IPs instead of Swarm `10.0.0.x` ingress addresses).
- The Technitium web UI is published only through Traefik at `dns.admin.${BASE_DOMAIN}`.
- Technitium is not pinned to a specific node; if one node is drained/down, Swarm can reschedule DNS to another node.

For HA without a VIP, advertise multiple Swarm node IPs as DNS servers in DHCP so clients can fail over between nodes.
If you want DNS settings and zones synced between nodes, configure Technitium Cluster in the web UI after initial deploy.

## Optional: Uptime Kuma

Deploy:

```bash
make swarm-deploy-uptime-kuma
```

Route: `https://uptime.${BASE_DOMAIN}`

## Optional: Backups (Restic -> NFS)

Set these in `swarm/env/cluster.env` or `swarm/env/cluster.env.local`:
- `BACKUP_NFS_SERVER` (for example `192.168.8.20`)
- `BACKUP_NFS_EXPORT` (for example `/exports/homelab-backups`)
- `BACKUP_NFS_VERSION` (for example `4.1`)
- `RESTIC_BACKUP_INTERVAL_SECONDS`
- `RESTIC_KEEP_DAILY`
- `RESTIC_KEEP_WEEKLY`
- `RESTIC_KEEP_MONTHLY`
- `RESTIC_MAX_REPO_BYTES` (for example `2199023255552` for 2 TiB cap)

Set `RESTIC_PASSWORD` in SOPS (`swarm/secrets/cluster-secrets.sops.yaml`), then deploy:

```bash
make swarm-deploy-backups
```

Behavior:
- Backs up `/mnt/homelab-data` (Gluster mount) to NFS-backed restic repo.
- Runs as one Swarm replica with no hostname pin, so it can reschedule on node failure.

## Security defaults in this stack

- Overlay networks use `encrypted: true`.
- Traefik only exposes services explicitly labeled with `traefik.enable=true`.
- TLS is enforced on all published app routes.
- Stateful services are pinned to the bootstrap node to avoid accidental data split across local volumes.

## Related

- [Service Catalog](../docs/SERVICE-CATALOG.md) | [[docs/SERVICE-CATALOG]]
- [Operations Notes](../docs/OPERATIONS.md) | [[docs/OPERATIONS]]
- [Secrets And SOPS](../docs/SECRETS-SOPS.md) | [[docs/SECRETS-SOPS]]
