{ lib, hostName, hostMeta, hosts, ... }:
let
  managedAdminPubKey = ../keys/homelab-admin.pub;
  hasManagedAdminPubKey = builtins.pathExists managedAdminPubKey;
  peerIPs = builtins.filter (ip: ip != hostMeta.ip) (builtins.map (h: h.ip) (builtins.attrValues hosts));
  keepalivedPriority =
    {
      k8s-0 = 200;
      k8s-1 = 150;
      k8s-2 = 100;
    }
    .${hostName} or 100;
in
{
  imports = [
    ../modules/common/base.nix
    ../modules/storage/gluster-replica.nix
    ../modules/swarm/cluster.nix
  ];

  users.users.root.openssh.authorizedKeys.keyFiles =
    lib.optional hasManagedAdminPubKey managedAdminPubKey;

  # Harden SSH once managed key exists in the repo.
  services.openssh.settings.PasswordAuthentication = if hasManagedAdminPubKey then false else true;
  services.openssh.settings.KbdInteractiveAuthentication = false;
  services.openssh.settings.PermitRootLogin = if hasManagedAdminPubKey then "prohibit-password" else "yes";

  services.keepalived = {
    enable = true;
    openFirewall = false;
    vrrpInstances.homelabVip = {
      interface = hostMeta.interface;
      state = if hostName == "k8s-0" then "MASTER" else "BACKUP";
      virtualRouterId = 51;
      priority = keepalivedPriority;
      unicastSrcIp = hostMeta.ip;
      unicastPeers = peerIPs;
      virtualIps = [
        {
          addr = "192.168.8.10/24";
          dev = hostMeta.interface;
        }
        {
          addr = "192.168.8.11/24";
          dev = hostMeta.interface;
        }
      ];
      trackInterfaces = [ hostMeta.interface ];
    };
  };

  networking.firewall.extraCommands = lib.mkAfter ''
    ip46tables -A nixos-fw -p vrrp -m comment --comment "homelab.keepalived.vrrp" -j ACCEPT || true
    ip46tables -A nixos-fw -p ah -m comment --comment "homelab.keepalived.ah" -j ACCEPT || true
    ip46tables -A nixos-fw -p esp -m comment --comment "homelab.overlay.esp" -j ACCEPT || true
  '';
}
