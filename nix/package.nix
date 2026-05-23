{ lib
, stdenv
, python3
, makeWrapper
, wineWow64Packages
, winetricks
, dxvk
, pkgsCross
, zenity
, rsync
, gnutar
, zstd
, curl
, wget
, coreutils
, gnused
, gnugrep
, busybox
, libcap
, systemd
, xset
, glib
, desktop-file-utils
, gtk3
, iproute2
, procps
, pciutils
, vulkan-tools
, mesa-demos
}:

let
  pythonEnv = python3.withPackages (ps: [ ps.rich ]);

  runtimeBins = lib.makeBinPath [
    pythonEnv
    wineWow64Packages.full
    winetricks
    dxvk
    pkgsCross.mingwW64.stdenv.cc
    pkgsCross.mingw32.stdenv.cc
    zenity
    rsync
    gnutar
    zstd
    curl
    wget
    coreutils
    gnused
    gnugrep
    busybox
    libcap
    systemd
    xset
    glib
    desktop-file-utils
    gtk3
    iproute2
    procps
    pciutils
    vulkan-tools
    mesa-demos
  ];
in

stdenv.mkDerivation {
  pname = "winema3";
  version = "0.1.0";

  src = ../.;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/winema3
    cp -r install.py probe.py uninstall.py wine_ma3 assets ma3onpcinstaller $out/libexec/winema3/

    # Allow overriding the repo root via environment variable so users can
    # keep their installer EXEs in a writable directory.
    substituteInPlace $out/libexec/winema3/install.py \
      --replace-fail 'REPO_ROOT = Path(__file__).resolve().parent' \
        'REPO_ROOT = Path(os.environ.get("WINEMA3_REPO_ROOT", __file__)).resolve().parent'

    mkdir -p $out/bin

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/winema3-install \
      --add-flags "$out/libexec/winema3/install.py" \
      --run 'if [ -z "$WINEMA3_REPO_ROOT" ] && [ -d "$PWD/ma3onpcinstaller" ]; then export WINEMA3_REPO_ROOT="$PWD"; fi' \
      --run 'if [ -z "$WINEMA3_REPO_ROOT" ]; then export WINEMA3_REPO_ROOT="$HOME/.local/share/winema3"; fi' \
      --run 'mkdir -p "$WINEMA3_REPO_ROOT/ma3onpcinstaller"' \
      --suffix PATH : ${runtimeBins} \
      --set DXVK_PATH "${dxvk}/share/dxvk" \
      --set PYTHONDONTWRITEBYTECODE 1

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/winema3-probe \
      --add-flags "$out/libexec/winema3/probe.py" \
      --suffix PATH : ${lib.makeBinPath [
        pythonEnv
        wineWow64Packages.full
        winetricks
        dxvk
        libcap
        systemd
        iproute2
        procps
        pciutils
        vulkan-tools
        mesa-demos
      ]} \
      --set PYTHONDONTWRITEBYTECODE 1

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/winema3-uninstall \
      --add-flags "$out/libexec/winema3/uninstall.py" \
      --suffix PATH : ${lib.makeBinPath [ pythonEnv ]} \
      --set PYTHONDONTWRITEBYTECODE 1

    runHook postInstall
  '';

  meta = {
    description = "Wine-only grandMA3 onPC installer";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "winema3-install";
  };
}
