{
  callPackage,
  runCommand,
  lib,
  pkgs,
  wine-packages,
  prefixBase,
  wintrustStub,
  registryPatches,
  ...
}:
let
  sources = callPackage ./sources.nix { };
  inherit (wine-packages) wine wineserver;
in
if sources.installer == null then
  runCommand "prefix-with-gma3-unavailable" { } ''
    mkdir -p $out
    echo "grandMA3 installer not available." > $out/README.txt
    echo "See packages/sources.nix for setup instructions." >> $out/README.txt
  ''
else
  runCommand "prefix-with-gma3"
    {
      nativeBuildInputs = [ pkgs.unzip ];
    }
    ''
      set -x -e

      mkdir -p $out
      cp -a ${prefixBase}/. $out
      chmod -R +w $out
      export WINEPREFIX="$out"

      # Install wintrust stub
      cp ${wintrustStub}/wintrust.dll $WINEPREFIX/drive_c/windows/system32/wintrust.dll

      # Apply registry patches
      ${lib.getExe wine} regedit /S "${registryPatches}/wintrust.reg"
      ${lib.getExe wine} regedit /S "${registryPatches}/dxvk.reg"

      # Resolve installer path (handle ZIP archives)
      installer="${sources.installer}"
      if [[ "$installer" == *.zip ]]; then
        mkdir -p /tmp/installer
        unzip "$installer" -d /tmp/installer
        installer=$(find /tmp/installer -name '*.exe' | head -n 1)
        if [[ -z "$installer" ]]; then
          echo "ERROR: No .exe found inside the ZIP archive" >&2
          exit 1
        fi
      fi

      # Install grandMA3
      ${lib.getExe wine} start /wait /unix "$installer" /S

      # Seed terminal config
      mkdir -p $WINEPREFIX/drive_c/ProgramData/MALightingTechnology/gma3_2.3.2/terminalapp/config
      echo -n -e '\x02\x00\x00\x00\x7f\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
        > $WINEPREFIX/drive_c/ProgramData/MALightingTechnology/gma3_2.3.2/terminalapp/config/terminal.cfg

      ${lib.getExe wineserver} -w

      rm -rf $WINEPREFIX/drive_c/users/nixbld
    ''
