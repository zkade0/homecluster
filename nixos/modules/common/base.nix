{ lib, pkgs, hostName, hostMeta, ... }:
{
  networking.hostName = hostName;

  networking.useDHCP = lib.mkForce false;
  networking.interfaces.${hostMeta.interface}.ipv4.addresses = [
    {
      address = hostMeta.ip;
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = hostMeta.gateway;
  networking.nameservers = hostMeta.nameservers;

  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";

  services.openssh.enable = true;

  # All nodes have an EFI /boot partition from the generated hardware configs.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  services.chrony.enable = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22
      53
      80
      443
      8080
      9443
    ];
    allowedUDPPorts = [
      53
    ];
  };

  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    jq
    vim
  ];

  system.stateVersion = "25.05";
}
