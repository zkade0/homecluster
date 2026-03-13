# NixOS + Docker Swarm Bootstrap Guide

This guide uses NixOS for host state and Docker Swarm for service orchestration.

## Layer model

- Layer 1 (NixOS): machine state (`disk`, `users`, `ssh`, `network`, `firewall`, Docker daemon hardening).
- Layer 2 (Swarm): app and platform services (`traefik`, `homepage`, `vaultwarden`, `romm`, `portainer`).

## 0) What this path does

- Uses NixOS on each node (`k8s-0`, `k8s-1`, `k8s-2`).
- Uses direct `nixos-rebuild` deployment from this repo.
- Bootstraps a Swarm with managers on all three nodes.
- Deploys the stack from `swarm/stacks/homelab.yaml`.

## 1) Prerequisites

- Nix installed on your workstation.
- NixOS installed on all 3 nodes.
- SSH access from workstation to each node (for first bootstrap this can be a non-root sudo user).
- `sops`, `age`, and `sshpass` installed locally.
- `.sops.yaml` updated with your real age recipient.

## 2) One-command host bootstrap (recommended)

From repo root:

```bash
make nixos-bootstrap \
  K8S0_SSH=kaden@192.168.8.50 \
  K8S1_SSH=kaden@192.168.8.56 \
  K8S2_SSH=kaden@192.168.8.226 \
  NEW_IP_K8S0=192.168.8.5 \
  NEW_IP_K8S1=192.168.8.6 \
  NEW_IP_K8S2=192.168.8.7 \
  BOOTSTRAP_PASSWORD=password \
  GATEWAY=192.168.8.1 \
  NAMESERVERS=1.1.1.1 \
  OS_DISK=/dev/nvme0n1 \
  DATA_DISK=/dev/sda \
  SSD_CACHE_GB=75 \
  FINAL_DEPLOY_USER=root
```

This script:

- uses one-time password auth for initial access, then installs a managed SSH key
- supports `current SSH IPs -> new static node IPs` during first deployment
- rotates root password (unless `ROTATE_ROOT_PASSWORD=0`)
- detects each node's primary interface
- copies each `/etc/nixos/hardware-configuration.nix`
- writes `nixos/hosts.nix` with Swarm roles/manager address
- deploys `k8s-0` then `k8s-1/2` (unless `DEPLOY=0`)
- captures disk details in `docs/NODE-DISK-INVENTORY.md`
- writes encrypted bootstrap credentials to `secrets/ssh/nixos-bootstrap.sops.yaml`

## 3) Build/join the Swarm

```bash
make swarm-bootstrap
```

This initializes the bootstrap manager and joins the other nodes based on `nixos/hosts.nix`.

## 4) Configure stack variables

Create local env files from template:

```bash
cp swarm/env/cluster.env.example swarm/env/cluster.env
cp swarm/env/cluster.env.example swarm/env/cluster.env.local
cp swarm/env/domain.txt.example swarm/env/domain.txt
```

Set baseline values in `swarm/env/cluster.env`:

```env
TIMEZONE=America/Denver
```

Set your private domain in `swarm/env/domain.txt` (gitignored):

```txt
your-private-domain.tld
```

## 5) Sync secrets + deploy stack

```bash
make swarm-sync-secrets
make swarm-deploy
```

`swarm-sync-secrets` decrypts `swarm/secrets/cluster-secrets.sops.yaml` and creates Swarm secrets on the manager.

## 6) Validate cluster and services

```bash
ssh root@192.168.8.5 'docker node ls'
ssh root@192.168.8.5 'docker service ls'
```

## 7) Restore managed SSH key on a new workstation (optional)

```bash
make nixos-restore-key
```

This restores:

- private key to `~/.ssh/homelab-nixos-admin`
- public key to `nixos/keys/homelab-admin.pub`

## Notes

- Stateful services are pinned to the bootstrap node by label (`homelab.tag.bootstrap=true`) to avoid split local volumes.
