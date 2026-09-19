# Prebuilt grandMA3 onPC Wine prefix.
#
# Downloads the proprietary MA Lighting onPC installer at evaluation/build time
# (never redistributed by this repo), runs it headlessly with DXVK and the
# wintrust stub, and captures the finished Wine prefix as a store path. The
# resulting derivation is unfree and embeds the proprietary software, so it
# must NOT be served from a PUBLIC binary cache.
#
# Defaults target the baked-in grandMA3 onPC 2.4.2.2 Windows installer. Override
# `src`, `version`, and `installDir` to target another release.
{ lib
, stdenv
, fetchurl
, unzip
, wineWow64Packages
, dxvk
, xvfb # nixpkgs "xorg-server"; provides Xvfb (passed via callPackage in flake.nix)
, coreutils
, findutils
, winema3
, version ? "2.4.2.2"
  # Directory name grandMA3 onPC installs into, and the prefix dir name the
  # gma3-wine launcher looks for under $XDG_DATA_HOME/winema3/. Must match
  # installer.install_dir_name (wine_ma3/installers.py) → "gma3_<major.minor.sub>".
, installDir ? "gma3_2.4.2"
, installer ? fetchurl {
    name = "grandMA3_onPC_win_v${version}.zip";
    url = "https://xom.malighting.com/xom-rest/assets/fb019be2-3317-49ff-9110-e04f2b9be5b4/content?access_token=9FKEHm7BKIFd3pJh-6OobEGYsas";
    sha256 = "1q2kascjp4bd2pnn8g88y0xgb8034nnsbbv957g21g1nnsa6xlci";
  }
}:

stdenv.mkDerivation {
  pname = "grandma3-onpc-prefix";
  inherit version;

  src = installer;
  dontUnpack = true;

  nativeBuildInputs = [
    unzip
    wineWow64Packages.full
    dxvk # provides setup_dxvk.sh
    xvfb # provides Xvfb
    coreutils
    findutils
  ];

  # Wine prefixes are inherently non-deterministic (timestamps, generated GUIDs),
  # but the derivation is keyed by its inputs, so a private cache still serves it fine.
  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    export WINEPREFIX="$TMPDIR/prefix"
    export WINEDEBUG=-all
    export WINEDLLOVERRIDES='mscoree,mshtml='
    export DXVK_LOG_PATH="$TMPDIR"
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    mkdir -p "$HOME"

    # Headless X server for wineboot / the silent installer.
    Xvfb :99 -screen 0 1280x1024x24 >/dev/null 2>&1 &
    xvfb_pid=$!
    export DISPLAY=:99
    sleep 2

    unzip -o "$src" -d "$TMPDIR/extracted" >/dev/null
    exe="$(find "$TMPDIR/extracted" -iname '*.exe' | head -1)"
    [ -n "$exe" ] || { echo "no installer EXE found inside $src" >&2; exit 1; }

    wineboot -u
    wineserver -w

    # Silent install of grandMA3 onPC.
    wine start /wait /unix "$exe" /S || true
    wineserver -w

    if [ ! -d "$WINEPREFIX/drive_c/Program Files/MALightingTechnology/${installDir}" ]; then
      echo "grandMA3 ${version} was not installed into the prefix" >&2
      exit 1
    fi

    # DXVK via the nixpkgs setup_dxvk.sh (DLL store paths baked in; no network).
    # setup_dxvk.sh uses `fold -w $COLUMNS` under `set -u`; COLUMNS is not always
    # set in non-interactive build environments, so provide a fallback.
    export COLUMNS="''${COLUMNS:-80}"
    setup_dxvk.sh install
    wineserver -w

    # wintrust stub (disables signature checks) — reuse the DLLs the winema3
    # package already cross-compiles, so no mingw toolchain is needed here.
    install -Dm644 ${winema3}/libexec/winema3/wintrust/wintrust-native.dll \
      "$WINEPREFIX/drive_c/windows/system32/wintrust.dll"
    if [ -e ${winema3}/libexec/winema3/wintrust/wintrust-native-x86.dll ]; then
      install -Dm644 ${winema3}/libexec/winema3/wintrust/wintrust-native-x86.dll \
        "$WINEPREFIX/drive_c/windows/syswow64/wintrust.dll"
    fi
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v '*wintrust' /t REG_SZ /d 'native,builtin' /f
    wine reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f
    wineserver -w

    kill "$xvfb_pid" 2>/dev/null || true

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r "$WINEPREFIX" "$out/${installDir}"
    runHook postInstall
  '';

  passthru = {
    inherit installDir;
  };

  meta = {
    description = "Prebuilt grandMA3 onPC ${version} Wine prefix (proprietary MA Lighting software)";
    homepage = "https://www.malighting.com/";
    # MA Lighting EULA — proprietary. Marked unfree so it must be explicitly
    # accepted, and so it is never served from a public cache by default.
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
}
