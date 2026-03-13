# Backup And Restore

This repo uses restic to back up shared app data from Gluster-backed paths to an external NFS target.

## Backup Model

- Source path: `/mnt/homelab-data`
- Service: `backups_restic-backup` (Swarm replicated, `replicas: 1`)
- Repo target inside container: `/restic-repo/homelab`
- Password source: Swarm secret `homelab_restic_password`
- Stack file: `swarm/stacks/backups.yaml`

## Important Variables

Set in `swarm/env/cluster.env` or `swarm/env/cluster.env.local`:

- `BACKUP_NFS_SERVER`
- `BACKUP_NFS_EXPORT`
- `BACKUP_NFS_VERSION`
- `RESTIC_BACKUP_INTERVAL_SECONDS`
- `RESTIC_KEEP_DAILY`
- `RESTIC_KEEP_WEEKLY`
- `RESTIC_KEEP_MONTHLY`
- `RESTIC_MAX_REPO_BYTES`

Set encrypted in SOPS source:

- `RESTIC_PASSWORD` in `swarm/secrets/cluster-secrets.sops.yaml`

## Deploy Or Update Backups

```bash
# Sync secrets from SOPS
SOPS_AGE_KEY_FILE=./age.agekey make swarm-sync-secrets

# Deploy backups stack
make swarm-deploy-backups MANAGER_SSH=root@<manager-ip> SSH_KEY_FILE=$HOME/.ssh/<keyfile>
```

## Health Checks

```bash
# Service state
ssh root@<manager-ip> 'docker service ls | grep backups_restic-backup'
ssh root@<manager-ip> 'docker service ps backups_restic-backup --no-trunc'

# Recent logs
ssh root@<manager-ip> 'docker service logs --tail 200 backups_restic-backup'
```

## Inspect Snapshot Metadata

```bash
# On the node currently running backups service
CID=$(docker ps --filter label=com.docker.swarm.service.name=backups_restic-backup --format "{{.ID}}" | head -n1)
docker exec "$CID" restic snapshots
docker exec "$CID" restic stats latest
```

## Browse Backups Read-Only

```bash
export RESTIC_REPOSITORY=/mnt/<backup-mount>/homelab
export RESTIC_PASSWORD="$(sops -d --extract '["stringData"]["RESTIC_PASSWORD"]' swarm/secrets/cluster-secrets.sops.yaml)"

mkdir -p /tmp/restic-ro
restic mount --no-default-permissions /tmp/restic-ro

# Browse:
# /tmp/restic-ro/snapshots/latest/source

fusermount -u /tmp/restic-ro
```

## Restore Workflow

```bash
# Restore latest snapshot to a temp path
restic restore latest --target /tmp/restore-test

# Restore one snapshot id
restic restore <snapshot-id> --target /tmp/restore-test
```

## Notes

- The 2 TiB cap is enforced in the backup loop after retention runs.
- This cap is practical policy-level pruning, not a hard filesystem quota.
- For a strict hard stop, also enforce quota on the NFS backend.
