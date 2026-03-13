{ hostMeta, hosts, ... }:
let
  peerIPs = builtins.map (h: h.ip) (builtins.attrValues hosts);
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  homelab.swarm = {
    enable = true;
    role = hostMeta.swarmRole;
    clusterInit = hostMeta.swarmManagerAddress == null;
    managerAddress = hostMeta.swarmManagerAddress;
    advertiseAddress = hostMeta.swarmAdvertiseAddr;
  };

  homelab.glusterReplica = {
    enable = true;
    dataDisk = hostMeta.dataDisk;
    peers = peerIPs;
  };
}
