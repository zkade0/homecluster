{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.swarm;
  swarmBootstrapScript = pkgs.writeShellScript "homelab-swarm-bootstrap" ''
    set -euo pipefail

    state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
    if [[ "''${state}" == "active" ]]; then
      exit 0
    fi

    if [[ "${if cfg.clusterInit then "1" else "0"}" != "1" ]]; then
      echo "Skipping swarm init on this node (clusterInit=false)."
      exit 0
    fi

    echo "Initializing Docker Swarm manager on ${cfg.advertiseAddress}"
    docker swarm init --advertise-addr ${lib.escapeShellArg cfg.advertiseAddress} >/dev/null 2>&1 || true
  '';
in
{
  options.homelab.swarm = {
    enable = lib.mkEnableOption "Docker Swarm node";

    role = lib.mkOption {
      type = lib.types.enum [ "manager" "worker" ];
      default = "manager";
      description = "Swarm node role for this host.";
    };

    clusterInit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether this node initializes the Swarm cluster.";
    };

    managerAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Manager address used by automation scripts to join this node.";
    };

    advertiseAddress = lib.mkOption {
      type = lib.types.str;
      description = "Address advertised by this node to the Swarm control plane.";
    };

    extraDaemonSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Additional Docker daemon settings merged into secure defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (!cfg.clusterInit) || (cfg.role == "manager");
        message = "homelab.swarm.clusterInit requires homelab.swarm.role = manager.";
      }
      {
        assertion = cfg.clusterInit || cfg.managerAddress != null;
        message = "homelab.swarm.managerAddress must be set when clusterInit = false.";
      }
    ];

    boot.kernelModules = [
      "overlay"
      "br_netfilter"
    ];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };

    virtualisation.docker = {
      enable = true;
      autoPrune.enable = true;
      daemon.settings =
        {
          "icc" = false;
          "iptables" = true;
          "log-driver" = "json-file";
          "log-opts" = {
            "max-file" = "5";
            "max-size" = "10m";
          };
          "userland-proxy" = false;
        }
        // cfg.extraDaemonSettings;
    };

    networking.firewall.allowedTCPPorts = [
      2377
      7946
    ];

    networking.firewall.allowedUDPPorts = [
      7946
      4789
    ];

    systemd.services.homelab-swarm-init = {
      description = "Initialize Docker Swarm on bootstrap manager";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "docker.service"
        "network-online.target"
      ];
      after = [
        "docker.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = swarmBootstrapScript;
      };
    };

    environment.systemPackages = with pkgs; [
      docker
    ];
  };
}
