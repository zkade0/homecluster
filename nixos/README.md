# NixOS Fleet (nixos-rebuild)

This folder manages homelab nodes with NixOS and plain `nixos-rebuild` deployment.

## Layout

- `flake.nix`: NixOS host outputs + dev shell
- `hosts.nix`: host inventory (IPs, users, NICs, swarm role, tags)
- `hosts/common.nix`: shared baseline config
- `hosts/k8s-*/configuration.nix`: per-node role config
- `modules/common/base.nix`: host OS baseline (network, ssh, firewall, nix)
- `modules/swarm/cluster.nix`: reusable Docker Swarm node module

## Quick usage

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
  NAMESERVERS=1.1.1.1

make swarm-bootstrap
make swarm-deploy
```

The bootstrap script pulls `hardware-configuration.nix` from each host and writes managed SSH key material into `nixos/keys/homelab-admin.pub` (public) plus encrypted private key bundle in `secrets/ssh/nixos-bootstrap.sops.yaml`.

Restore the managed key on another workstation with:

```bash
make nixos-restore-key
```

Detailed runbook: `../docs/NIXOS-DEPLOY.md`.
