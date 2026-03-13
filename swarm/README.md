# Docker Swarm Layout

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
- `stacks/local-dns.yaml`: Technitium DNS stack (single replica, served via VIP)
- `stacks/speedtest.yaml`: LibreSpeed Rust stack (single replica behind Traefik)

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

Details: `docs/SWARM-RECONCILE.md`

## Domain setup

Create your local domain file:

```bash
cp swarm/env/domain.txt.example swarm/env/domain.txt
```

Put your private base domain on the first non-comment line of `swarm/env/domain.txt`.

## Optional: local DNS (Technitium)

Set `TECHNITIUM_ADMIN_PASSWORD` in `swarm/env/cluster.env.local` (gitignored), then deploy:

```bash
make swarm-deploy-technitium-dns
```

Recommended LAN client DNS behavior:
- Hand out `192.168.8.10` (keepalived VIP) as DHCP DNS so clients query Technitium directly.
- Do not set a public secondary DNS (for example `1.1.1.1`) if you want full per-client visibility/filtering in Technitium.
- Technitium DNS is exposed on `53/tcp` and `53/udp` in host publish mode (preserves real client source IPs instead of Swarm `10.0.0.x` ingress addresses).
- The Technitium web UI is published only through Traefik at `dns.admin.${BASE_DOMAIN}`.
- Current stack pins Technitium to `k8s-0` so VIP `192.168.8.10` and host-published DNS stay aligned.

For HA without a VIP, advertise multiple Swarm node IPs as DNS servers in DHCP so clients can fail over between nodes.
If you want DNS settings and zones synced between nodes, configure Technitium Cluster in the web UI after initial deploy.

## Security defaults in this stack

- Overlay networks use `encrypted: true`.
- Traefik only exposes services explicitly labeled with `traefik.enable=true`.
- TLS is enforced on all published app routes.
- Stateful services are pinned to the bootstrap node to avoid accidental data split across local volumes.
