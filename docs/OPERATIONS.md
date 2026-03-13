# Operations Notes

## Useful commands

```bash
make swarm-bootstrap
make swarm-sync-secrets
make swarm-deploy
make swarm-deploy-monitoring
make swarm-reconcile

ssh root@192.168.8.5 'docker node ls'
ssh root@192.168.8.5 'docker service ls'
ssh root@192.168.8.5 'docker service ps homelab_traefik'
ssh root@192.168.8.5 'docker service logs --tail 100 homelab_traefik'
```

## Update stack env

1. Edit `swarm/env/cluster.env` for non-sensitive defaults.
2. Set private base domain in `swarm/env/domain.txt` (gitignored).
3. Put other private overrides in `swarm/env/cluster.env.local` (gitignored).
4. Redeploy:

```bash
make swarm-deploy
```

## Monitoring dashboard (separate stack mode)

- Deploy first: `make swarm-deploy-monitoring`
- URL: `http://grafana.${BASE_DOMAIN}` (for example `http://grafana.example.com`)
- Default datasource: Prometheus (auto-provisioned)
- Home dashboard: `Swarm Overview` (auto-provisioned)
- Login defaults come from `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` in `swarm/env/cluster.env`

Deploy or refresh monitoring after env changes:

```bash
make swarm-deploy-monitoring
```

## Rotate a secret value

1. Update encrypted source value in `swarm/secrets/cluster-secrets.sops.yaml`.
2. Re-sync secrets:

```bash
FORCE_REPLACE=1 make swarm-sync-secrets
```

3. Redeploy stack:

```bash
make swarm-deploy
```

## Add a new app

1. Add service definition in `swarm/stacks/homelab.yaml`.
2. Add Traefik labels and attach to `edge` network.
3. If needed, add a new Swarm secret and map it in `scripts/swarm-sync-secrets.sh`.
4. Deploy with `make swarm-deploy`.

## Reconcile stacks (manual GitOps style)

Run from this repo on your workstation; it deploys remotely to your Swarm manager:

```bash
make swarm-reconcile SSH_KEY_FILE=~/.ssh/homelab-nixos-admin MANAGER_SSH=root@192.168.8.5
```

Useful overrides:

```bash
# Only selected stacks
make swarm-reconcile STACKS=traefik,local-dns,monitoring

# One explicit stack file
make swarm-reconcile STACK_FILE=swarm/stacks/romm.yaml

# Dry-run
make swarm-reconcile DRY_RUN=1
```

Behavior:
- Discovers stack files under `swarm/stacks/` (or uses `STACKS`/`STACK_FILE`)
- Renders env vars from `swarm/env/cluster.env` (+ optional `.local`) and `swarm/env/domain.txt`
- Syncs SOPS secrets first (unless `SYNC_SECRETS=0`)
- Deploys each stack and waits for replica convergence
- Rolls back failed stack to `dist/swarm-reconcile/last-good/<stack>.yaml`
- Sends Discord notification if `DISCORD_WEBHOOK_URL` is set

Detailed reference: `docs/SWARM-RECONCILE.md`
