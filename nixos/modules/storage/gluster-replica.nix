{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.glusterReplica;
  mountPath = "/mnt/homelab-data";
  brickPath = "/srv/brick";
  brickLabel = "hlab-brick";
  primaryPeer = builtins.head cfg.peers;
  backupPeers = lib.tail cfg.peers;
in
{
  options.homelab.glusterReplica = {
    enable = lib.mkEnableOption "GlusterFS replica-backed shared storage";

    dataDisk = lib.mkOption {
      type = lib.types.str;
      example = "/dev/sda";
      description = "Raw disk device used for the Gluster brick (destructive on first apply).";
    };

    volumeName = lib.mkOption {
      type = lib.types.str;
      default = "homelab";
      description = "Gluster volume name mounted for shared app data.";
    };

    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Ordered list of Gluster peer IPs in the cluster.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.length cfg.peers >= 2;
        message = "homelab.glusterReplica.peers must contain at least two peers.";
      }
    ];

    services.glusterfs = {
      enable = true;
      useRpcbind = false;
      logLevel = "WARNING";
    };

    networking.firewall.allowedTCPPorts = [
      24007
      24008
    ];

    networking.firewall.allowedTCPPortRanges = [
      {
        from = 49152;
        to = 60999;
      }
    ];

    boot.supportedFilesystems = [ "glusterfs" ];

    systemd.services.homelab-brick-init = {
      description = "Initialize and format Gluster brick disk";
      before = [ "srv-brick.mount" ];
      requiredBy = [ "srv-brick.mount" ];
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      path = with pkgs; [
        coreutils
        gawk
        parted
        util-linux
        xfsprogs
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        disk="${cfg.dataDisk}"
        if [[ ! -b "${cfg.dataDisk}" ]]; then
          echo "Disk not found: ${cfg.dataDisk}" >&2
          exit 1
        fi

        if [[ "''${disk}" =~ [0-9]$ ]]; then
          part="''${disk}p1"
        else
          part="''${disk}1"
        fi

        if [[ ! -b "''${part}" ]]; then
          parted -s "''${disk}" mklabel gpt
          parted -s "''${disk}" mkpart primary xfs 1MiB 100%
          partprobe "''${disk}" || true
          udevadm settle
        fi

        fs_type="$(blkid -s TYPE -o value "''${part}" 2>/dev/null || true)"
        fs_label="$(blkid -s LABEL -o value "''${part}" 2>/dev/null || true)"

        if [[ -z "''${fs_type}" ]]; then
          mkfs.xfs -f -L ${brickLabel} "''${part}"
        elif [[ "''${fs_type}" == "xfs" ]]; then
          if [[ "''${fs_label}" != "${brickLabel}" ]]; then
            xfs_admin -L ${brickLabel} "''${part}"
          fi
        else
          mkfs.xfs -f -L ${brickLabel} "''${part}"
        fi
      '';
    };

    fileSystems."${brickPath}" = {
      device = "/dev/disk/by-label/${brickLabel}";
      fsType = "xfs";
      options = [
        "nofail"
        "x-systemd.device-timeout=10s"
      ];
    };

    fileSystems."${mountPath}" = {
      device = "${primaryPeer}:/${cfg.volumeName}";
      fsType = "glusterfs";
      options =
        [
          "_netdev"
          "nofail"
          "x-systemd.automount"
          "x-systemd.idle-timeout=300"
        ]
        ++ map (peer: "backupvolfile-server=${peer}") backupPeers;
    };
  };
}
