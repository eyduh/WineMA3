{ inputs, ... }:
{
  imports = [
    ./wine
  ];

  perSystem =
    { config, pkgs, craneLib, toolchain, wine-packages, wineUnwrapped, ... }:
    let
      stdPath = [
        pkgs.zenity
        pkgs.curl
        pkgs.zstd
        pkgs.coreutils
        pkgs.gnused
        pkgs.gnugrep
        pkgs.wget
        pkgs.busybox
        pkgs.fuse-overlayfs
      ];

      prefixBase = pkgs.callPackage ./basePrefix.nix {
        inherit inputs wine-packages;
      };

      wintrustStub = pkgs.callPackage ./wintrust.nix { };

      registryPatches = pkgs.callPackage ./registry-patches.nix { };

      runner = pkgs.callPackage ./runner/package.nix {
        inherit craneLib stdPath wine-packages prefixBase registryPatches;
      };

      desktopItems = pkgs.callPackage ./desktopItems.nix { };

      icons = pkgs.callPackage ./icons.nix { };
    in
    {
      packages = {
        winema3-prefix = prefixBase;
        winema3-wintrust = wintrustStub;
        winema3-registry-patches = registryPatches.combined;
        winema3-runner = runner;
        winema3 = pkgs.symlinkJoin {
          name = "winema3";
          paths = [
            runner
            desktopItems.gma3
            icons.iconPackage
          ];
        };
        default = config.packages.winema3;
      };

      _module.args = {
        inherit prefixBase wintrustStub registryPatches;
      };
    };
}
