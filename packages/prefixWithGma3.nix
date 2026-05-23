{
  runCommand,
  lib,
  wine-packages,
  prefixBase,
  wintrustStub,
  registryPatches,
  installer,
  ...
}:
let
  inherit (wine-packages) wine wineserver;
in
runCommand "prefix-with-gma3"
  {
    nativeBuildInputs = [ ];
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

    # Install grandMA3
    ${lib.getExe wine} start /wait /unix "${installer}" /S

    # Seed terminal config
    mkdir -p $WINEPREFIX/drive_c/ProgramData/MALightingTechnology/gma3_2.3.2/terminalapp/config
    echo -n -e '\x02\x00\x00\x00\x7f\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
      > $WINEPREFIX/drive_c/ProgramData/MALightingTechnology/gma3_2.3.2/terminalapp/config/terminal.cfg

    ${lib.getExe wineserver} -w

    rm -rf $WINEPREFIX/drive_c/users/nixbld
  ''
