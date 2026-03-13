# Swarm Reconcile Pipeline

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Documentation Index](INDEX.md) | [[docs/INDEX]]
- [Swarm Layout](../swarm/README.md) | [[swarm/README]]
- [Operations Notes](OPERATIONS.md) | [[docs/OPERATIONS]]

This document explains the manual GitOps-like pipeline for Docker Swarm in this repo.

The entrypoint is:

```bash
make swarm-reconcile
```

It runs from your local repo/workstation and deploys remotely to the Swarm manager over SSH.

## What it does

`scripts/swarm-reconcile.sh` performs these steps:

1. Load env vars from local `swarm/env/cluster.env` and optional `swarm/env/cluster.env.local`, then load `BASE_DOMAIN` from `swarm/env/domain.txt` when present.
2. Optionally sync SOPS secrets to Swarm (`scripts/swarm-sync-secrets.sh`).
3. Discover stack files in `swarm/stacks/` (or use selected stacks only).
4. Render each stack with `envsubst`.
5. Deploy each stack with `docker stack deploy --prune --with-registry-auth`.
6. Wait for service replicas to converge (`running == desired` for all services).
7. Save successful rendered config as last-known-good.
8. If a stack fails deploy/health check, auto-rollback that stack to last-known-good.
9. Optionally send a Discord webhook notification with summary status.

## Why this exists

You keep Swarm compose files in git and reconcile from one command, similar to Flux behavior, while staying fully in Docker Swarm and keeping manual control of when deploys happen.

## Stack discovery rules

Default discovery scans:

- `swarm/stacks/*.yaml`
- `swarm/stacks/*.yml`
- `swarm/stacks/*/stack.yaml|stack.yml|compose.yaml|compose.yml`

Default exclusions:

- `homelab`

This default avoids deploying the combined stack accidentally.

## Stack naming rules

By default:

- `swarm/stacks/romm.yaml` -> stack name `romm`
- `swarm/stacks/monitoring.yaml` -> stack name `monitoring`
- `swarm/stacks/traefik/stack.yaml` -> stack name `traefik`

## State and rollback files

The pipeline writes local state to:

- `dist/swarm-reconcile/rendered/<stack>.yaml`
- `dist/swarm-reconcile/last-good/<stack>.yaml`

Rollback uses `last-good/<stack>.yaml`.

If no last-known-good exists for a failing stack, rollback cannot run for that stack.

## Commands

Run all discovered stacks:

```bash
make swarm-reconcile \
  MANAGER_SSH=root@192.168.8.5 \
  SSH_KEY_FILE=$HOME/.ssh/homelab-nixos-admin
```

Run only selected stacks:

```bash
make swarm-reconcile \
  STACKS=traefik,local-dns,monitoring,romm \
  MANAGER_SSH=root@192.168.8.5 \
  SSH_KEY_FILE=$HOME/.ssh/homelab-nixos-admin
```

Run one explicit file:

```bash
make swarm-reconcile \
  STACK_FILE=swarm/stacks/romm.yaml \
  MANAGER_SSH=root@192.168.8.5 \
  SSH_KEY_FILE=$HOME/.ssh/homelab-nixos-admin
```

Dry-run (render + plan only):

```bash
make swarm-reconcile DRY_RUN=1 SYNC_SECRETS=0 STACKS=monitoring
```

## Important env vars

- `STACK_FILE`: deploy exactly one stack file.
- `STACKS`: comma-separated stack names/paths.
- `STACKS_DIR`: discovery root (default `swarm/stacks`).
- `EXCLUDE_STACKS`: comma-separated names excluded from auto-discovery.
- `ENV_FILE`: default `swarm/env/cluster.env`.
- `ENV_LOCAL_FILE`: default `swarm/env/cluster.env.local`.
- `DOMAIN_FILE`: default `swarm/env/domain.txt` (first non-comment line becomes `BASE_DOMAIN`).
- `SYNC_SECRETS`: `1` or `0`.
- `FORCE_REPLACE`: passed to secret sync script.
- `DEPLOY_TIMEOUT`: per-stack health timeout seconds (default `180`).
- `POLL_INTERVAL`: health poll seconds (default `5`).
- `DISCORD_WEBHOOK_URL`: optional notifications.
- `MANAGER_SSH`: explicit target (recommended in homelab use).
- `SSH_KEY_FILE`: SSH key path (supports `~/...` and relative paths).

## Failure behavior

If deploy or health check fails for a stack:

1. Mark stack as failed.
2. Attempt rollback for that stack only.
3. Continue processing remaining stacks.
4. Exit non-zero if any stack failed.

This keeps one bad stack from blocking all other reconciles.

## Troubleshooting

If it cannot connect to manager:

- Verify `MANAGER_SSH` and `SSH_KEY_FILE`.
- Test manually: `ssh -i $HOME/.ssh/homelab-nixos-admin root@192.168.8.5`.

If secrets sync fails:

- Validate SOPS file decrypts locally:
  `sops -d swarm/secrets/cluster-secrets.sops.yaml >/dev/null`

If a stack keeps rolling back:

- Inspect stack services:
  `ssh root@192.168.8.5 "docker stack services <stack>"`
- Inspect tasks:
  `ssh root@192.168.8.5 "docker service ps <stack>_<service> --no-trunc"`
- Inspect logs:
  `ssh root@192.168.8.5 "docker service logs --tail 200 <stack>_<service>"`

## Related

- [Stack From Compose](STACK-FROM-COMPOSE.md) | [[docs/STACK-FROM-COMPOSE]]
- [Secrets And SOPS](SECRETS-SOPS.md) | [[docs/SECRETS-SOPS]]
- [Backup And Restore](BACKUP-RESTORE.md) | [[docs/BACKUP-RESTORE]]
