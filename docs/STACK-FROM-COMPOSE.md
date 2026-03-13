# Build And Deploy A New Swarm Stack From Compose

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Documentation Index](INDEX.md) | [[docs/INDEX]]
- [Swarm Layout](../swarm/README.md) | [[swarm/README]]
- [Swarm Reconcile](SWARM-RECONCILE.md) | [[docs/SWARM-RECONCILE]]

Use this runbook to onboard a new app from Docker Compose into this repo's Swarm workflow.

## Naming Convention (Required)

- Stack file path: `swarm/stacks/<stack-name>.yaml`
- Stack name: `<stack-name>`
- App hostname: `<stack-name>.${BASE_DOMAIN}`

This keeps file name, stack name, Traefik host rule, and DNS record aligned.

## Preferred Path: One Command

Run the onboarding target with your compose file:

```bash
make swarm-onboard-from-compose COMPOSE_FILE=swarm/stacks/jellyfin.yaml DRY_RUN=1
```

Default behavior of this workflow:

- Converts Compose to Swarm-safe stack YAML.
- Enforces Traefik-forwarded ingress for the routed app service.
- Removes published node ports (`ports:`) so traffic goes through Traefik instead of node IPs.
- Adds persistent storage binds under `/mnt/homelab-data/<stack>/...`.
- Ensures stack hostname uses `<stack-name>.${BASE_DOMAIN}`.
- Upserts Technitium DNS `A` record to Traefik VIP `192.168.8.11`.
- Runs strict preflight checks to block leaked inline secrets before deploy.
- Validates rendered stack with `docker compose config`.
- Deploys with `make swarm-reconcile` (unless `DEPLOY=0`).

Common overrides:

```bash
make swarm-onboard-from-compose \
  COMPOSE_FILE=./jellyfin.yaml \
  ROUTE_SERVICE=jellyfin \
  SERVICE_PORT=8096 \
  DRY_RUN=0 \
  DEPLOY=1
```

## Required Inputs

- Swarm already bootstrapped.
- `swarm/env/cluster.env` exists.
- Optional overrides in `swarm/env/cluster.env.local`.
- `swarm/env/domain.txt` contains `${BASE_DOMAIN}`.
- For DNS automation, Technitium API must be reachable (default `http://dns.admin.${BASE_DOMAIN}`).
- DNS automation is token-only; provide `TECHNITIUM_API_TOKEN` from SOPS (`TECHNITIUM_API_TOKEN` key).

## Secret Safety Rules

- Do not keep secrets inline in `environment:` values in compose or stack YAML.
- Use Swarm secrets (`secrets:` + `/run/secrets/...` or `*_FILE`) for secret-bearing app config.
- Onboarding preflight blocks deploy when inline secret literals are detected.

## DNS Policy (VIP Only)

The app host must resolve to Traefik ingress VIP only:

- Record: `<stack-name>.<BASE_DOMAIN>`
- Type: `A`
- Value: `192.168.8.11`

Do not publish app hosts to individual node IPs (`192.168.8.5/.6/.7`).

Manual verification:

```bash
BASE_DOMAIN="$(awk 'NF && $1 !~ /^#/ {print $1; exit}' swarm/env/domain.txt | tr -d '\r')"
nslookup jellyfin.${BASE_DOMAIN} 192.168.8.10
```

## Compose-To-Swarm Conversion Rules

The onboarding script applies these rules:

- Drops Swarm-unsafe keys: `build`, `container_name`, `restart`, `depends_on`, `links`, `profiles`.
- Adds `deploy` defaults (`replicas`, `placement`, `restart_policy`, `update_config`).
- Adds/keeps `edge` network for Traefik-routed service.
- Generates Traefik HTTP->HTTPS forwarding labels and secure router labels.
- Uses `${BASE_DOMAIN}`, `${TIMEZONE}`, `${STACK_NAME}` conventions.
- Converts non-external volumes to persistent bind-backed volumes under `/mnt/homelab-data/<stack>/...`.
- Converts non-external secrets to external Swarm secret references (`homelab_*`) and prints warnings so you can add SOPS mappings.

## Secrets Workflow

When the converter warns about externalized secrets:

1. Add secret values to `swarm/secrets/cluster-secrets.sops.yaml`.
2. Map/create them in `scripts/swarm-sync-secrets.sh`.
3. Re-run onboarding with `SYNC_SECRETS=1` or run `make swarm-sync-secrets` manually.

## Deploy Modes

Reconcile-first (preferred):

```bash
make swarm-onboard-from-compose COMPOSE_FILE=./jellyfin.yaml
```

Dry run only:

```bash
make swarm-onboard-from-compose COMPOSE_FILE=./jellyfin.yaml DRY_RUN=1 DEPLOY=0
```

Preflight only (no DNS, no deploy side effects):

```bash
make swarm-onboard-from-compose COMPOSE_FILE=./jellyfin.yaml PREFLIGHT_ONLY=1
```

Direct deploy (secondary path):

```bash
make swarm-deploy STACK_FILE=swarm/stacks/jellyfin.yaml STACK_NAME=jellyfin SYNC_SECRETS=0
```

Use reconcile for repeatable updates and rollback behavior.

## Worked Example

1. Start with `swarm/stacks/jellyfin.yaml` (Compose format).
2. Run onboarding:

```bash
make swarm-onboard-from-compose COMPOSE_FILE=swarm/stacks/jellyfin.yaml ROUTE_SERVICE=jellyfin SERVICE_PORT=8096
```

3. Script writes/updates `swarm/stacks/jellyfin.yaml` in Swarm format.
4. Script upserts DNS `jellyfin.${BASE_DOMAIN} -> 192.168.8.11` in Technitium.
5. Script reconciles deployment.
6. Verify:

```bash
ssh root@192.168.8.5 'docker stack services jellyfin'
BASE_DOMAIN="$(awk 'NF && $1 !~ /^#/ {print $1; exit}' swarm/env/domain.txt | tr -d '\r')"
nslookup jellyfin.${BASE_DOMAIN} 192.168.8.10
```

Open `https://jellyfin.${BASE_DOMAIN}`.

## Manual Fallback (No Automation)

If needed, you can still do manual conversion and deployment:

```bash
make swarm-reconcile STACK_FILE=swarm/stacks/<stack-name>.yaml DRY_RUN=1
make swarm-reconcile STACK_FILE=swarm/stacks/<stack-name>.yaml
```

## Related

- [Service Catalog](SERVICE-CATALOG.md) | [[docs/SERVICE-CATALOG]]
- [Secrets And SOPS](SECRETS-SOPS.md) | [[docs/SECRETS-SOPS]]
- [Operations Notes](OPERATIONS.md) | [[docs/OPERATIONS]]
