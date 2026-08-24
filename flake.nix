{
  description = "Disposable NixOS VPS gateway — public ingress for Jellyfin/home services over Tailscale/WireGuard";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, ... }:
    let
      # Flip to "aarch64-linux" for ARM instances (Netcup ARM / UpCloud ARM / Hetzner CAX).
      # Because deployment uses --build-on-remote, the CI runner arch does not matter.
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          vars = import ./vars.nix;
        };
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./disk-config.nix
          ./configuration.nix
        ];
      };
    };
}
