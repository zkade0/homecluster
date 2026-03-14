{
  description = "homelab NixOS host configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      hosts = import ./hosts.nix;

      mkSystem =
        name: host:
        lib.nixosSystem {
          inherit system;
          specialArgs = {
            hostName = name;
            hostMeta = host;
            inherit hosts;
          };
          modules = [
            ./hosts/common.nix
            ./hosts/${name}/configuration.nix
          ];
        };
    in
    {
      homelab.hosts = hosts;

      nixosConfigurations = lib.mapAttrs mkSystem hosts;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          git
          openssh
        ];
      };
    };
}
