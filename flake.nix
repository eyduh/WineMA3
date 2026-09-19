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
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "grandma3-onpc-prefix";
        };
        wineMa3 = pkgs.callPackage ./nix/package.nix { };

        # Prebuilt, UNFREE grandMA3 onPC Wine prefix. The installer is fetched from
        # MA Lighting by Nix at eval time (never redistributed by this repo) and the
        # prefix is built headlessly. See nix/onpc-prefix.nix. Once built it can be
        # served from a PRIVATE binary cache and pulled by your other devices.
        onpcPrefix = pkgs.callPackage ./nix/onpc-prefix.nix {
          winema3 = wineMa3;
          xvfb = pkgs."xorg-server";
          dxvk = pkgs.dxvk.bin;
        };

        # Idempotent helper: copies the prebuilt prefix into the writable XDG
        # location the launcher reads. Used declaratively by the NixOS/Home Manager
        # modules; also usable manually with `nix run .#winema3-install-prefix`.
        installPrefixApp = pkgs.callPackage ./nix/onpc-prefix-install.nix { } {
          prefix = onpcPrefix;
        };
      in
      {
        packages = {
          default = wineMa3;
          winema3 = wineMa3;
          # Unfree — build with NIXPKGS_ALLOW_UNFREE=1 (or nixpkgs.config.allowUnfree).
          onpc-prefix = onpcPrefix;
          winema3-install-prefix = installPrefixApp;
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
