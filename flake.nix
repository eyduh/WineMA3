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

        # Prebuilt, UNFREE grandMA3 onPC Wine prefix (you supply the installer via
        # requireFile). Building it needs allowUnfree; see nix/onpc-prefix.nix. Once
        # built (e.g. on a licensed machine) it can be served from a PRIVATE binary
        # cache and pulled by your other devices, skipping the runtime install.
        onpcPrefix = pkgs.callPackage ./nix/onpc-prefix.nix {
          winema3 = wineMa3;
          xvfb = pkgs."xorg-server";
        };

        # Copies the prebuilt prefix into the writable XDG location the launcher
        # reads. Run once per device: `nix run .#winema3-install-prefix`.
        installPrefixApp = pkgs.writeShellApplication {
          name = "winema3-install-prefix";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            dest="''${XDG_DATA_HOME:-$HOME/.local/share}/winema3"
            target="$dest/gma3_2.3.2"
            mkdir -p "$dest"
            if [ -e "$target" ]; then
              echo "A prefix already exists at $target." >&2
              echo "Remove it first if you want to replace it with the prebuilt one." >&2
              exit 1
            fi
            echo "Copying prebuilt grandMA3 onPC prefix into $target ..."
            cp -r --no-preserve=mode,ownership "${onpcPrefix}/gma3_2.3.2" "$target"
            chmod -R u+w "$target"
            echo "Done. Launch with gma3-wine."
          '';
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
      };

      nixosModules.default = import ./nix/nixos-module.nix;
      nixosModules.winema3 = import ./nix/nixos-module.nix;

      homeModules.default = import ./nix/home-module.nix { inherit nixgl; };
      homeModules.winema3 = import ./nix/home-module.nix { inherit nixgl; };
    };
}
