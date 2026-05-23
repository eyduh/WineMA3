{ inputs, ... }:
{
  perSystem = { pkgs, ... }:
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
        pkgs.unzip
      ];
      wine-packages = pkgs.callPackage ./packages.nix {
        inherit stdPath inputs;
      };
    in
    {
      packages.wine = wine-packages.wine;

      _module.args = {
        inherit (wine-packages) wineUnwrapped;
        inherit wine-packages;
      };
    };
}
