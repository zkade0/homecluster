# Secrets And SOPS

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Documentation Index](INDEX.md) | [[docs/INDEX]]
- [First-Try Checklist](FIRST-TRY-CHECKLIST.md) | [[docs/FIRST-TRY-CHECKLIST]]
- [Operations Notes](OPERATIONS.md) | [[docs/OPERATIONS]]

This runbook keeps secrets out of git while still enabling reproducible deploys.

## Source Of Truth

- Encrypted source file: `swarm/secrets/cluster-secrets.sops.yaml`
- Runtime target: Docker Swarm secrets on manager nodes
- Sync script: `scripts/swarm-sync-secrets.sh`

## Key Handling

- Keep your age private key local only (for example `./age.agekey`).
- Never commit private keys.
- `.gitignore` already excludes common private key paths and `*.agekey`.

## Secret Sync

```bash
SOPS_AGE_KEY_FILE=./age.agekey make swarm-sync-secrets \
  MANAGER_SSH=root@<manager-ip> \
  SSH_KEY_FILE=$HOME/.ssh/<keyfile>
```

## Common App Secrets

Store these in `swarm/secrets/cluster-secrets.sops.yaml`:

- `GRAFANA_ADMIN_PASSWORD`
- `TECHNITIUM_ADMIN_PASSWORD` (local DNS stack)
- `PAPERLESS_SECRET_KEY` (Paperless stack)
- `RESTIC_PASSWORD` (backups stack)

## Rotate One Secret

```bash
# Example: rotate RESTIC_PASSWORD in encrypted source
SOPS_AGE_KEY_FILE=./age.agekey sops --set '["stringData"]["RESTIC_PASSWORD"] "<new-value>"' \
  -i swarm/secrets/cluster-secrets.sops.yaml

# Replace runtime Swarm secrets
SOPS_AGE_KEY_FILE=./age.agekey FORCE_REPLACE=1 make swarm-sync-secrets \
  MANAGER_SSH=root@<manager-ip> \
  SSH_KEY_FILE=$HOME/.ssh/<keyfile>
```

## Common Failures

- `Failed to get the data key required to decrypt`: wrong/missing age key.
- `secret is in use by the following service`: update service first or redeploy stack after secret rotation.
- `data is empty` during sync: expected secret key is missing in SOPS file.

## Hygiene Rules

- Keep real secrets only in SOPS files and Swarm secret store.
- Keep `swarm/env/cluster.env` non-sensitive.
- Keep `swarm/env/cluster.env.local` for local non-secret overrides and never commit.
- Use `${BASE_DOMAIN}` placeholders in documentation and examples.

## Related

- [Swarm Reconcile](SWARM-RECONCILE.md) | [[docs/SWARM-RECONCILE]]
- [Stack From Compose](STACK-FROM-COMPOSE.md) | [[docs/STACK-FROM-COMPOSE]]
- [Swarm Layout](../swarm/README.md) | [[swarm/README]]
