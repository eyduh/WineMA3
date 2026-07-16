# Prebuilt grandMA3 onPC Wine prefix.
#
# Runs the proprietary MA Lighting onPC installer (supplied by you via
# requireFile — never redistributed), DXVK, and the wintrust stub headlessly at
# BUILD time, and captures the finished Wine prefix as a store path. Copy it into
# place on a device with `winema3-install-prefix` instead of re-running the whole
# install — the store path is content-addressed by inputs, so once built (e.g. on
# arcus) it can be pulled from a private binary cache (Harmonia) by your devices.
#
# UNFREE: the output embeds grandMA3 onPC, proprietary MA Lighting software. It is
# marked unfree so you must explicitly accept it (NIXPKGS_ALLOW_UNFREE=1 or
# nixpkgs.config.allowUnfree). Do NOT serve it from a PUBLIC cache — that
# redistributes MA's software. A private/authenticated cache for your own
# licensed devices is the intended use.
{ lib
, stdenv
, requireFile
, unzip
, wineWow64Packages
, dxvk
, xvfb # nixpkgs "xorg-server"; provides Xvfb (passed via callPackage in flake.nix)
, coreutils
, findutils
, winema3
, version ? "2.3.2.0"
  # Directory name grandMA3 onPC installs into, and the prefix dir name the
  # gma3-wine launcher looks for under $XDG_DATA_HOME/winema3/. Must match
  # installer.install_dir_name (wine_ma3/installers.py) → "gma3_<major.minor.sub>".
, installDir ? "gma3_2.3.2"
}:

stdenv.mkDerivation {
  pname = "grandma3-onpc-prefix";
  inherit version;

  # You supply the file. Compute the hash once with:
  #   nix hash file grandMA3_onPC_win_v2.3.2.0.zip
  # then add it to the store so the build can find it:
  #   nix store add-file --name grandMA3_onPC_win_v2.3.2.0.zip <path>
  src = requireFile {
    name = "grandMA3_onPC_win_v${version}.zip";
    sha256 = lib.fakeSha256; # TODO: replace with the real hash (see message)
    message = ''
      grandMA3 onPC ${version} is proprietary MA Lighting software and is not
      redistributed by this flake. Download grandMA3_onPC_win_v${version}.zip
      from MA Lighting (https://www.malighting.com/), then:

        nix hash file grandMA3_onPC_win_v${version}.zip   # get the sha256
        # put that hash in nix/onpc-prefix.nix (src.sha256), then:
        nix store add-file --name grandMA3_onPC_win_v${version}.zip \
          /path/to/grandMA3_onPC_win_v${version}.zip
    '';
  };

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
  # but the derivation is keyed by its inputs, so a cache still serves it fine.
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
