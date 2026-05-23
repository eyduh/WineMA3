{ runCommand, writeText, lib }:
rec {
  wintrust-override = writeText "wintrust-override.reg" ''
    Windows Registry Editor Version 5.00

    [HKEY_CURRENT_USER\Software\Wine\DllOverrides]
    "wintrust"="native,builtin"
  '';

  dxvk-override = writeText "dxvk-override.reg" ''
    Windows Registry Editor Version 5.00

    [HKEY_CURRENT_USER\Software\Wine\DllOverrides]
    "dxgi"="native"
    "d3d11"="native"
  '';

  combined = runCommand "registry-patches-combined" { } ''
    mkdir -p $out
    cp ${wintrust-override} $out/wintrust.reg
    cp ${dxvk-override} $out/dxvk.reg
  '';
}
