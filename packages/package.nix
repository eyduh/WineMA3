{ pkgs, craneLib, wine-packages, wineUnwrapped, prefixBase, wintrustStub, registryPatches }:
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

  runner = pkgs.callPackage ./runner/package.nix {
    inherit craneLib stdPath wine-packages prefixBase registryPatches;
  };

  desktopItems = pkgs.callPackage ./desktopItems.nix { };

  icons = pkgs.callPackage ./icons.nix { };
in
pkgs.symlinkJoin {
  name = "winema3";
  paths = [
    runner
    desktopItems.gma3
    icons.iconPackage
  ];
}
