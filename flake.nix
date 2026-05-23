{
  description = "WineMA3 -- Nix-native grandMA3 onPC runner with Wine, DXVK, and overlayfs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, crane, fenix, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [
        ./nix/shells.nix
        ./packages
        ./overlay.nix
        ./tests
      ];

      perSystem = { config, pkgs, system, ... }: {
        _module.args = {
          craneLib = (crane.mkLib pkgs).overrideToolchain config._module.args.toolchain.toolchain;
          toolchain = fenix.packages.${system}.complete;
        };
      };
    };
}
