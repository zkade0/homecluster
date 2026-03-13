# Service Catalog

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Documentation Index](INDEX.md) | [[docs/INDEX]]
- [Swarm Layout](../swarm/README.md) | [[swarm/README]]
- [Operations Notes](OPERATIONS.md) | [[docs/OPERATIONS]]

This catalog maps user-facing endpoints to stack files.
All hostnames use `${BASE_DOMAIN}` placeholders by design.

## Public Routes

- `dns.admin.${BASE_DOMAIN}` -> Technitium web UI
  - Stack: `swarm/stacks/local-dns.yaml`
- `uptime.${BASE_DOMAIN}` -> Uptime Kuma
  - Stack: `swarm/stacks/uptime-kuma.yaml`
- `romm.${BASE_DOMAIN}` -> RomM
  - Stack: `swarm/stacks/romm.yaml`
- `paperless.${BASE_DOMAIN}` -> Paperless-ngx
  - Stack: `swarm/stacks/paperless.yaml`
- `speedtest.${BASE_DOMAIN}` -> LibreSpeed Rust
  - Stack: `swarm/stacks/speedtest.yaml`
- `grafana.${BASE_DOMAIN}` -> Grafana
  - Stack: `swarm/stacks/monitoring.yaml`

## Internal DNS

- DNS resolver service is `local-dns_technitium-dns`.
- DNS query endpoint is LAN DNS on `53/tcp` and `53/udp`.
- Recommended DHCP DNS target is your Technitium VIP/address for consistent policy and visibility.

## Optional Or Existing Split Stacks

- `forgejo` may be deployed as a separate stack in live Swarm even if no stack file is present in `swarm/stacks/`.
- If deployed, the expected host is typically `git.${BASE_DOMAIN}`.

## Verify Routes

```bash
# See active stacks
ssh root@<manager-ip> 'docker stack ls'

# Inspect live labels for a service
ssh root@<manager-ip> 'docker service inspect <stack>_<service> --format "{{json .Spec.Labels}}"'

# Validate DNS resolution from a client
nslookup <host>.${BASE_DOMAIN} <dns-server-ip>
```

## Related

- [Swarm Reconcile](SWARM-RECONCILE.md) | [[docs/SWARM-RECONCILE]]
- [Backup And Restore](BACKUP-RESTORE.md) | [[docs/BACKUP-RESTORE]]
- [Stack From Compose](STACK-FROM-COMPOSE.md) | [[docs/STACK-FROM-COMPOSE]]
