{
  description = "WineMA3 — Wine-only grandMA3 onPC installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      supportedSystems = [ "x86_64-linux" ];
    in
    flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        wineMa3 = pkgs.callPackage ./nix/package.nix { };
      in
      {
        packages = {
          default = wineMa3;
          winema3 = wineMa3;
        };

        apps = {
          default = {
            type = "app";
            program = "${wineMa3}/bin/winema3-install";
          };
          install = {
            type = "app";
            program = "${wineMa3}/bin/winema3-install";
          };
          probe = {
            type = "app";
            program = "${wineMa3}/bin/winema3-probe";
          };
          uninstall = {
            type = "app";
            program = "${wineMa3}/bin/winema3-uninstall";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            (python3.withPackages (ps: [ ps.rich ]))
            wineWow64Packages.full
            winetricks
            dxvk
            pkgsCross.mingwW64.stdenv.cc
            pkgsCross.mingw32.stdenv.cc
            zenity
            rsync
            gnutar
            zstd
            curl
            wget
            coreutils
            gnused
            gnugrep
            busybox
            libcap
            xorg.xset
            glib
            desktop-file-utils
            gtk3
            iproute2
            procps
            pciutils
            vulkan-tools
            glxinfo
          ];
          shellHook = ''
            export DXVK_PATH="${pkgs.dxvk}/share/dxvk"
          '';
        };
      })
    // {
      overlays.default = final: prev: {
        winema3 = final.callPackage ./nix/package.nix { };
      };

      nixosModules.default = import ./nix/nixos-module.nix;
      nixosModules.winema3 = import ./nix/nixos-module.nix;
    };
}
