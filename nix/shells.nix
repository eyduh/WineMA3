{ inputs, ... }:
{
  perSystem =
    { config, pkgs, craneLib, toolchain, ... }:
    {
      devShells.default = craneLib.devShell {
        packages = [
          pkgs.wineWow64Packages.full
          pkgs.winetricks
          pkgs.fuse-overlayfs
          pkgs.zenity
          pkgs.rsync
          pkgs.gnutar
          pkgs.zstd
          toolchain.toolchain
        ];
      };
    };
}
