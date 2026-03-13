# Architecture

## Navigation

- [Repository Home](../README.md) | [[README]]
- [Documentation Index](INDEX.md) | [[docs/INDEX]]
- [NixOS Deploy](NIXOS-DEPLOY.md) | [[docs/NIXOS-DEPLOY]]
- [Swarm Layout](../swarm/README.md) | [[swarm/README]]

## Node topology

- 3 nodes total
- All nodes run Docker Swarm manager role
- Nodes:
  - `k8s-0` (`192.168.8.5`): i5-11400T, 16GB RAM
  - `k8s-1` (`192.168.8.6`): i5-9600T, 16GB RAM
  - `k8s-2` (`192.168.8.7`): i5-11400T, 16GB RAM

## Networking

- LAN: `192.168.8.0/24` (assumed)
- Swarm control-plane port: `2377/tcp`
- Swarm gossip ports: `7946/tcp+udp`
- Swarm overlay data plane: `4789/udp`
- Ingress: `80/tcp`, `443/tcp` via Traefik on manager nodes

## Control/data flow

1. NixOS config provisions Docker daemon + firewall + host settings.
2. `scripts/swarm-bootstrap.sh` initializes/join Swarm nodes.
3. `scripts/swarm-deploy.sh` deploys `swarm/stacks/homelab.yaml`.
4. Traefik routes traffic to labeled services.

## Security model

- Secret source-of-truth: SOPS + age
- Runtime secrets: Docker Swarm secrets
- TLS automation: Traefik + Let’s Encrypt DNS challenge
- Host hardening: NixOS firewall + SSH key-only mode after bootstrap

## Storage model

- Service data uses Docker named volumes.
- Stateful services are pinned to bootstrap node (`k8s-0`) unless you add shared storage.

## Related

- [Service Catalog](SERVICE-CATALOG.md) | [[docs/SERVICE-CATALOG]]
- [Operations Notes](OPERATIONS.md) | [[docs/OPERATIONS]]
- [First-Try Checklist](FIRST-TRY-CHECKLIST.md) | [[docs/FIRST-TRY-CHECKLIST]]
