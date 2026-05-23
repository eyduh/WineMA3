{ fetchurl, pkgs, lib }:
rec {
  iconPackage = pkgs.runCommand "winema3-icons" { } ''
    mkdir -p $out/share/icons/hicolor/scalable/apps
    cp ${./assets/winema3-grandma3.svg} $out/share/icons/hicolor/scalable/apps/winema3-grandma3.svg
  '';
}
