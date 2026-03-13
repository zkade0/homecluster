# Documentation Index

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Swarm Layout](../swarm/README.md) | [[swarm/README]]
- [NixOS Fleet](../nixos/README.md) | [[nixos/README]]

Use this page as the starting point for homelab operations.

## Core

- [Repository Home](../README.md): top-level project overview and quick start.
- [Swarm Layout](../swarm/README.md): stack layout, env files, and split-stack deployment flow.
- [Architecture](ARCHITECTURE.md): cluster and storage architecture notes.
- [NixOS Deploy](NIXOS-DEPLOY.md): NixOS bootstrap and deployment flow.
- [First-Try Checklist](FIRST-TRY-CHECKLIST.md): pre-flight checklist before first deploy.
- [Stack From Compose](STACK-FROM-COMPOSE.md): create a new stack from compose and deploy via reconcile.

## Day-2 Operations

- [Operations Notes](OPERATIONS.md): frequent commands and operator tasks.
- [Swarm Reconcile](SWARM-RECONCILE.md): reconcile pipeline behavior and rollback model.
- [Service Catalog](SERVICE-CATALOG.md): FQDN/service map and stack ownership.
- [Backup And Restore](BACKUP-RESTORE.md): backup behavior, verification, and restore runbook.
- [Secrets And SOPS](SECRETS-SOPS.md): SOPS/age workflow and secret hygiene rules.

## Related

- [[docs/FIRST-TRY-CHECKLIST]] -> [[docs/NIXOS-DEPLOY]] -> [[docs/SWARM-RECONCILE]]
- [[docs/OPERATIONS]] <-> [[docs/SERVICE-CATALOG]] <-> [[docs/BACKUP-RESTORE]]
