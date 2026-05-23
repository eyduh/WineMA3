{
  callPackage,
  runCommand,
  writeText,
  xvfb-run,
  lib,
  wine-packages,
  ...
}:
let
  inherit (wine-packages) wine winetricks wineserver;

  layer_1 = runCommand "base-prefix-1" { } ''
    set -x -e
    mkdir -p $out
    export WINEPREFIX="$out"
    export WINETRICKS_UPDATE_CHECK=0
    export WINETRICKS_LATEST_VERSION_CHECK=disabled

    mkdir -p /tmp/cache
    export XDG_CACHE_HOME="/tmp/cache"

    ${lib.getExe wine} wineboot --update

    # Disable file association, menu builder, and Mono/Gecko prompts
    ${lib.getExe wine} regedit /S "${(writeText "prefix-tweaks.reg" ''
      Windows Registry Editor Version 5.00

      [HKEY_CURRENT_USER\Software\Wine\DllOverrides]
      "winemenubuilder.exe"=""
      "mscoree"=""
      "mshtml"=""

      [HKEY_CURRENT_USER\Software\Wine\FileOpenAssociations]
      "Enable"="N"
    '').outPath}"

    ${lib.getExe wineserver} -w
  '';

  layer_2 = runCommand "base-prefix-2"
    {
      nativeBuildInputs = [ xvfb-run ];
    }
    ''
      set -x -e

      mkdir -p $out
      cp -a ${layer_1}/. $out
      chmod -R +w $out
      export WINEPREFIX="$out"

      mkdir -p /tmp/cache
      export XDG_CACHE_HOME="/tmp/cache"

      ${lib.getExe wine} winecfg -v win10

      ${lib.getExe wineserver} -w
    '';
in
layer_2
