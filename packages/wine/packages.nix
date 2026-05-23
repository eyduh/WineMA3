{
  stdenv,
  callPackage,
  pkgs,
  inputs,
  stdPath,
}:
let
  wineUnstable = pkgs.wineWow64Packages.full;

  symlink = callPackage ./symlink.nix { };

  wineUnwrapped = symlink {
    wine = wineUnstable;
  };

  wrapWithPrefix = callPackage ./wrapWithPrefix.nix {
    inherit wineUnwrapped stdPath;
  };
in
{
  inherit wineUnwrapped;

  wine = wrapWithPrefix wineUnwrapped "wine";
  winetricks = wrapWithPrefix pkgs.winetricks "winetricks";
  wineserver = wrapWithPrefix wineUnwrapped "wineserver";
}
