{
  description = "WineMA3 — Wine-only grandMA3 onPC installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, nixgl }:
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
            xset
            glib
            desktop-file-utils
            gtk3
            iproute2
            procps
            pciutils
            vulkan-tools
            mesa-demos
          ];
          shellHook = ''
            export DXVK_PATH="${pkgs.dxvk}/share/dxvk"
          '';
        };
      })
    // {
      overlays.default = final: prev: {
        winema3 = final.callPackage ./nix/package.nix { };

        # Patched Wine with WM_TOUCH synthesis from XI2 touch events.
        # Implements RegisterTouchWindow / GetTouchInputInfo so apps like
        # grandMA3 onPC receive touch events instead of ignoring them.
        wineWow64Packages = prev.wineWow64Packages // {
          full = prev.wineWow64Packages.full.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.python3 ];
            postPatch = (old.postPatch or "") + ''
              python3 ${./nix/wine-wm-touch.py}
            '';
          });
        };
      };

      nixosModules.default = import ./nix/nixos-module.nix;
      nixosModules.winema3 = import ./nix/nixos-module.nix;

      homeModules.default = import ./nix/home-module.nix { inherit nixgl; };
      homeModules.winema3 = import ./nix/home-module.nix { inherit nixgl; };
    };
}
