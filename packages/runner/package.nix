{
  pkgs,
  craneLib,
  lib,
  stdPath,
  wine-packages,
  prefixBase,
  registryPatches,
  ...
}:
let
  src = craneLib.cleanCargoSource ../..;
  commonArgs = {
    inherit src;
    strictDeps = true;
  };
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  env = {
    LOWER_DIR = prefixBase;
    WINE = lib.getExe wine-packages.wine;
    WINESERVER = lib.getExe wine-packages.wineserver;
    WINETRICKS = lib.getExe wine-packages.winetricks;
    FUSE_OVERLAYFS = lib.getExe pkgs.fuse-overlayfs;
    GNUTAR = lib.getExe pkgs.gnutar;
    ZENITY = lib.getExe pkgs.zenity;
    RSYNC = lib.getExe pkgs.rsync;
    DXVK = "${pkgs.dxvk.bin}/x64";
  };
in
craneLib.buildPackage (
  commonArgs // {
    inherit cargoArtifacts env;
    pname = "winema3-runner";
    cargoExtraArgs = "-p runner";
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postInstall = ''
      mv $out/bin/runner $out/bin/winema3-runner
      wrapProgram $out/bin/winema3-runner \
        --prefix PATH : "${lib.makeBinPath stdPath}"
    '';
  }
)
