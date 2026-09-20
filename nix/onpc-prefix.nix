# Prebuilt grandMA3 onPC Wine prefix.
#
# Downloads the proprietary MA Lighting onPC installer at evaluation/build time
# (never redistributed by this repo), runs it headlessly with DXVK and the
# wintrust stub, and captures the finished Wine prefix as a store path. The
# resulting derivation is unfree and embeds the proprietary software, so it
# must NOT be served from a PUBLIC binary cache.
#
# Defaults target grandMA3 onPC 2.3.2.0, the last release known to launch with
# current nixpkgs Wine in this project. 2.4.2.2 currently crashes on startup
# (null-pointer write in app_gma3.exe after graphics/audio init). Override
# `installer`, `version`, and `installDir` to opt into newer releases.
#
# NOTE: MA Lighting's CDN URLs carry short-lived access tokens. If the default
# fetchurl fails with a 403, obtain a fresh link from
# https://www.malighting.com/downloads/products/ and override the `installer`
# argument, or point it at a local file with pkgs.requireFile / path:/... .
{ lib
, stdenv
, fetchurl
, unzip
, wineWow64Packages
, dxvk
, xvfb # nixpkgs "xorg-server"; provides Xvfb (passed via callPackage in flake.nix)
, coreutils
, findutils
, fontconfig
, winema3
, version ? "2.3.2.0"
  # Directory name grandMA3 onPC installs into, and the prefix dir name the
  # gma3-wine launcher looks for under $XDG_DATA_HOME/winema3/. Must match
  # installer.install_dir_name (wine_ma3/installers.py) → "gma3_<major.minor.sub>".
, installDir ? "gma3_${lib.concatStringsSep "." (lib.take 3 (lib.splitVersion version))}"
, installer ? fetchurl {
    name = "grandMA3_onPC_win_v${version}.zip";
    url = "https://xom.malighting.com/xom-rest/assets/8cbc9bd0-a929-40a7-8c04-b273ef69f5ba/content?access_token=9uVxy2CoQ7gqXyq5Un3VyX2Cw_A";
    sha256 = "185lgywgqs1sv8pnv5blqqx6709v1mbj8pgfqhm5dl9mqa37i10r";
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
    dxvk # DLL output; flake.nix passes pkgs.dxvk.bin
    xvfb # provides Xvfb
    coreutils
    findutils
    fontconfig # silence "Cannot load default config file" sandbox noise
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
    # Silence Wine/Fontconfig warnings about missing default config in the sandbox.
    export FONTCONFIG_FILE="${fontconfig}/etc/fonts/fonts.conf"
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

    # Install DXVK manually.  nixpkgs' setup_dxvk.sh can mis-detect the Wow64
    # layout and copy the 32-bit DLLs into system32, which makes the x64 app
    # crash with c000007b when it loads d3d11.dll.  We know the layout, so copy
    # the right files to the right directories and set the overrides ourselves.
    dxvk_install() {
      local arch="$1" srcdir="$2" dstdir="$3"
      [ -d "$dstdir" ] || mkdir -p "$dstdir"
      for dll in d3d8.dll d3d9.dll d3d10.dll d3d10_1.dll d3d10core.dll d3d11.dll dxgi.dll; do
        if [ -f "''${srcdir}/''${dll}" ]; then
          if [ -f "''${dstdir}/''${dll}" ] && [ ! -f "''${dstdir}/''${dll}.old" ]; then
            mv -f "''${dstdir}/''${dll}" "''${dstdir}/''${dll}.old"
          fi
          install -m 755 "''${srcdir}/''${dll}" "''${dstdir}/''${dll}"
          wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d native /f > /dev/null
        fi
      done
    }
    dxvk_install x64 "${dxvk}/x64" "$WINEPREFIX/drive_c/windows/system32"
    dxvk_install x32 "${dxvk}/x32" "$WINEPREFIX/drive_c/windows/syswow64"
    wineserver -w

    # Verify the x64 d3d11.dll is really in system32.  A mismatch here means the
    # app will crash on launch with STATUS_INVALID_IMAGE_FORMAT.
    if [ "$(wc -c < "$WINEPREFIX/drive_c/windows/system32/d3d11.dll")" != "$(wc -c < "${dxvk}/x64/d3d11.dll")" ]; then
      echo "ERROR: DXVK x64 d3d11.dll was not installed into system32" >&2
      exit 1
    fi
    if [ "$(wc -c < "$WINEPREFIX/drive_c/windows/syswow64/d3d11.dll")" != "$(wc -c < "${dxvk}/x32/d3d11.dll")" ]; then
      echo "ERROR: DXVK x32 d3d11.dll was not installed into syswow64" >&2
      exit 1
    fi

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
