# homecluster: NixOS + Docker Swarm Homelab

This repo now uses a NixOS-first provisioning workflow and Docker Swarm for service orchestration.

## Provisioning options

- `NixOS + Docker Swarm + nixos-rebuild`: `nixos/` + `swarm/`

## Design choices

- 3 nodes managed declaratively with NixOS
- Docker Swarm managers on all nodes (HA control plane)
- Traefik ingress + Let’s Encrypt DNS challenge
- Prometheus + Grafana monitoring dashboard for Swarm nodes/services
- SOPS + age for secret source-of-truth
- Simple stack-based app deployment (`docker stack deploy`)

## Layer split

- Layer 1 (`nixos/`): node OS provisioning only.
- Layer 2 (`swarm/`): service stack and runtime operations.

## Repo layout

- `nixos/`: host inventory + NixOS modules + flake outputs
- `swarm/`: stack definitions, env, and ingress config
- `scripts/`: bootstrap/deploy automation for NixOS and Swarm
- `docs/`: operational runbooks

## Documentation Map

- `docs/INDEX.md`: doc index and quick navigation
- `docs/ARCHITECTURE.md`: cluster architecture summary
- `docs/NIXOS-DEPLOY.md`: bootstrap and deployment flow
- `docs/OPERATIONS.md`: day-2 operations commands
- `docs/SERVICE-CATALOG.md`: route and stack ownership map
- `docs/BACKUP-RESTORE.md`: backup and restore runbook
- `docs/SECRETS-SOPS.md`: secret management with SOPS/age
- `docs/SWARM-RECONCILE.md`: reconcile pipeline details

## Quick start (NixOS + Swarm)

Detailed steps: `docs/NIXOS-DEPLOY.md`

```bash
# 1) Bootstrap hosts and deploy NixOS
make nixos-bootstrap \
  K8S0_SSH=kaden@192.168.8.50 \
  K8S1_SSH=kaden@192.168.8.56 \
  K8S2_SSH=kaden@192.168.8.226 \
  NEW_IP_K8S0=192.168.8.5 \
  NEW_IP_K8S1=192.168.8.6 \
  NEW_IP_K8S2=192.168.8.7 \
  BOOTSTRAP_PASSWORD=password \
  GATEWAY=192.168.8.1 \
  NAMESERVERS=1.1.1.1

# 2) Build the Swarm cluster
make swarm-bootstrap

# 3) Sync SOPS secrets to Swarm and deploy stack
make swarm-sync-secrets
make swarm-deploy

# Optional: reconcile split stacks (manual Flux-like flow)
make swarm-reconcile

# 4) On a new workstation, restore managed SSH key from SOPS secret
make nixos-restore-key
```

## Swarm reconcile pipeline (manual)

Use this when you want one command to reconcile one/many stack files from `swarm/stacks/` with:
- env rendering (`cluster.env` + optional `.local` + `domain.txt`)
- optional SOPS secret sync
- deploy + health check
- rollback to last-known-good on failure
- optional Discord webhook notifications

Examples:

```bash
# Reconcile all discovered stacks (excluding default EXCLUDE_STACKS)
make swarm-reconcile SSH_KEY_FILE=~/.ssh/homelab-nixos-admin MANAGER_SSH=root@192.168.8.5

# Reconcile only selected stacks by name
make swarm-reconcile STACKS=traefik,local-dns,monitoring SSH_KEY_FILE=~/.ssh/homelab-nixos-admin MANAGER_SSH=root@192.168.8.5

# Reconcile one explicit stack file
make swarm-reconcile STACK_FILE=swarm/stacks/romm.yaml SSH_KEY_FILE=~/.ssh/homelab-nixos-admin MANAGER_SSH=root@192.168.8.5
```

Full guide: `docs/SWARM-RECONCILE.md`
