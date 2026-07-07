"""Wine prefix, patch, and launcher generation."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from .installers import MaInstaller
from .system import run


WINTRUST_C = r"""#include <stdarg.h>
#include <windef.h>
#include <winbase.h>
#include <wintrust.h>

LONG WINAPI WinVerifyTrust(HWND hwnd, GUID *action_id, LPVOID data)
{
    SetLastError(ERROR_SUCCESS);
    return ERROR_SUCCESS;
}

HRESULT WINAPI WinVerifyTrustEx(HWND hwnd, GUID *action_id, WINTRUST_DATA *data)
{
    SetLastError(ERROR_SUCCESS);
    return S_OK;
}

BOOL WINAPI WintrustAddActionID(GUID *pgActionID, DWORD fdwFlags, CRYPT_REGISTER_ACTIONID *psActionID)
{
    SetLastError(ERROR_SUCCESS);
    return TRUE;
}

BOOL WINAPI WintrustRemoveActionID(GUID *pgActionID)
{
    SetLastError(ERROR_SUCCESS);
    return TRUE;
}

HRESULT WINAPI DllRegisterServer(void)
{
    return S_OK;
}

HRESULT WINAPI DllUnregisterServer(void)
{
    return S_OK;
}
"""

WINTRUST_DEF = """LIBRARY wintrust.dll
EXPORTS
    WinVerifyTrust
    WinVerifyTrustEx
    WintrustAddActionID
    WintrustRemoveActionID
    DllRegisterServer
    DllUnregisterServer
"""

TERMINAL_CFG = bytes.fromhex(
    "02 00 00 00 7f 00 00 01"
    " 00 00 00 00 00 00 00 00"
    " 00 00 00 00 00 00 00 00"
    " 00 00 00 00"
)


def _xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local/share"))


def prefix_path(installer: MaInstaller) -> Path:
    # The Wine prefix is regenerable state, so it lives in the XDG data dir (not a dotdir in
    # $HOME). User show data is externalised under grandMA3/ (see link_user_data_dirs) so the
    # prefix itself can be treated as disposable / excluded from backups.
    return _xdg_data_home() / "winema3" / installer.install_dir_name


def _user_data_root() -> Path:
    return _xdg_data_home() / "grandMA3"


def link_user_data_dirs(installer: MaInstaller) -> None:
    """Relocate MA3 user data (shows, backups, cross-version library) to a stable XDG path and
    symlink it back into the prefix, so it survives prefix wipes and version bumps and can be
    backed up independently of the disposable prefix. Idempotent."""
    prefix = prefix_path(installer)
    shared = (
        prefix / "drive_c/ProgramData/MALightingTechnology" / installer.install_dir_name / "shared"
    )
    library = prefix / "drive_c/ProgramData/MALightingTechnology/gma3_library"
    root = _user_data_root()
    root.mkdir(parents=True, exist_ok=True)
    for src, name in [(shared / "shows", "shows"), (shared / "backups", "backups"), (library, "library")]:
        dst = root / name
        if src.is_symlink():
            continue
        src.parent.mkdir(parents=True, exist_ok=True)
        if not dst.exists():
            if src.exists():
                shutil.move(str(src), str(dst))
            else:
                dst.mkdir(parents=True, exist_ok=True)
        elif src.exists():
            # XDG target already holds the real data; drop the freshly-created default in the prefix
            shutil.rmtree(str(src))
        src.symlink_to(dst)


def wine_env(prefix: Path) -> dict[str, str]:
    env = os.environ.copy()
    runtime_dir = env.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    env.update(
        {
            "DISPLAY": env.get("DISPLAY", ":0"),
            "XDG_RUNTIME_DIR": runtime_dir,
            "DBUS_SESSION_BUS_ADDRESS": env.get("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime_dir}/bus"),
            "WINEPREFIX": str(prefix),
            "WINEARCH": "win64",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "MESA_GL_VERSION_OVERRIDE": "4.2",
            "MESA_GLSL_VERSION_OVERRIDE": "420",
            "DXVK_LOG_LEVEL": "info",
            "DXVK_LOG_PATH": str(Path.home() / "ma3-wine-tests" / "2.3.2-clean" / "dxvk"),
        }
    )
    return env


def runtime_wine_env(prefix: Path) -> dict[str, str]:
    env = wine_env(prefix)
    env["WINEDLLOVERRIDES"] = "wintrust=n,b;dxgi,d3d11=n"
    return env


def install_prefix(installer: MaInstaller, repo_root: Path, *, run_installer: bool = True) -> None:
    prefix = prefix_path(installer)
    setup_env = wine_env(prefix)
    installer_exe = installer.resolve_exe(repo_root)
    if prefix_initialized(prefix) and not prefix_usable(setup_env):
        backup = prefix.with_name(f"{prefix.name}.broken.{_timestamp()}")
        shutil.move(str(prefix), str(backup))
    if not prefix_initialized(prefix):
        run(["wineboot", "-u"], check=True, env=setup_env)
    if run_installer:
        run(["wine", "start", "/wait", "/unix", str(installer_exe), "/S"], check=True, env=setup_env)

    if not ma_version_installed(installer):
        raise RuntimeError(f"grandMA3 {installer.version} was not found after running the MA installer")
    seed_terminal_config(installer)
    create_launchers(installer)

    install_dxvk(setup_env)
    build_and_install_wintrust(prefix, setup_env)
    run(
        ["wine", "reg", "add", r"HKCU\Software\Wine\DllOverrides", "/v", "*wintrust", "/t", "REG_SZ", "/d", "native,builtin", "/f"],
        check=True,
        env=runtime_wine_env(prefix),
    )
    run(
        ["wine", "reg", "add", r"HKCU\Software\Wine\WineDbg", "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"],
        check=True,
        env=runtime_wine_env(prefix),
    )
    link_user_data_dirs(installer)
    create_launchers(installer)


def _is_nixos() -> bool:
    from .system import read_os_release
    os_release = read_os_release()
    return "nixos" in f"{os_release.get('ID', '')} {os_release.get('ID_LIKE', '')}".lower()


def install_dxvk(env: dict[str, str]) -> None:
    attempts: list[str] = []
    if shutil.which("winetricks"):
        if _try_dxvk_command(["winetricks", "-q", "dxvk"], env, attempts):
            return
    if shutil.which("dxvk-setup"):
        if _try_dxvk_command(["dxvk-setup", "install"], env, attempts):
            return
    if _is_nixos():
        # Prefer the official nixpkgs setup_dxvk.sh when available
        if shutil.which("setup_dxvk.sh"):
            if _try_dxvk_command(["setup_dxvk.sh", "install"], env, attempts):
                return
        # Fallback to manual copy from nix store
        dxvk_path = _find_nixos_dxvk()
        if dxvk_path:
            _install_dxvk_from_path(dxvk_path, env)
            return
        attempts.append("NixOS: DXVK setup failed. Neither setup_dxvk.sh nor dxvk package found.")
    if not attempts:
        raise RuntimeError("DXVK setup requires either winetricks or Debian's dxvk-setup")
    raise RuntimeError("DXVK setup failed:\n\n" + "\n\n".join(attempts))


def _find_nixos_dxvk() -> Path | None:
    import os
    env_path = os.environ.get("DXVK_PATH")
    if env_path and Path(env_path).joinpath("x64/d3d11.dll").exists():
        return Path(env_path)
    # Search PATH for dxvk package directory
    for p in os.environ.get("PATH", "").split(":"):
        if "dxvk" in p and Path(p).joinpath("x64/d3d11.dll").exists():
            return Path(p)
    # Search nix store as fallback
    try:
        import subprocess as sp
        result = sp.run(
            ["find", "/nix/store", "-maxdepth", "1", "-name", "*dxvk*", "-type", "d"],
            capture_output=True, text=True, timeout=5,
        )
        for line in result.stdout.strip().split("\n"):
            d = Path(line)
            if d.joinpath("x64/d3d11.dll").exists():
                return d
    except Exception:
        pass
    return None


def _install_dxvk_from_path(dxvk_path: Path, env: dict[str, str]) -> None:
    prefix = Path(env.get("WINEPREFIX", Path.home() / ".wine"))
    system32 = prefix / "drive_c/windows/system32"
    syswow64 = prefix / "drive_c/windows/syswow64"
    system32.mkdir(parents=True, exist_ok=True)
    syswow64.mkdir(parents=True, exist_ok=True)

    x64_dlls = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]
    x32_dlls = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]

    def _copy_dll(src: Path, dst: Path) -> None:
        if not src.exists():
            return
        if dst.exists():
            import os
            os.chmod(dst, 0o644)
            dst.unlink()
        shutil.copy2(src, dst)

    for dll in x64_dlls:
        _copy_dll(dxvk_path / "x64" / dll, system32 / dll)

    for dll in x32_dlls:
        _copy_dll(dxvk_path / "x32" / dll, syswow64 / dll)

    # Set registry overrides for DXVK DLLs
    from .system import run as _run
    _run(
        ["wine", "reg", "add", r"HKCU\Software\Wine\DllOverrides", "/v", "dxgi", "/t", "REG_SZ", "/d", "native", "/f"],
        check=False, env=env,
    )
    _run(
        ["wine", "reg", "add", r"HKCU\Software\Wine\DllOverrides", "/v", "d3d11", "/t", "REG_SZ", "/d", "native", "/f"],
        check=False, env=env,
    )


def _try_dxvk_command(command: list[str], env: dict[str, str], attempts: list[str]) -> bool:
    try:
        result = run(command, check=True, capture=True, env=env)
    except subprocess.CalledProcessError as exc:
        output = (exc.stdout or "").strip() or "<no output>"
        attempts.append(f"$ {' '.join(command)}\nexit {exc.returncode}\n{output}")
        return False
    output = (result.stdout or "").strip()
    if output:
        attempts.append(f"$ {' '.join(command)}\n{output}")
    return True


def prefix_initialized(prefix: Path) -> bool:
    return (prefix / "system.reg").exists() and (prefix / "drive_c/windows").exists()


def prefix_usable(env: dict[str, str]) -> bool:
    result = run(["wine", "cmd", "/c", "ver"], capture=True, env=env)
    return result.returncode == 0


def ma_version_installed(installer: MaInstaller) -> bool:
    bin_dir = (
        prefix_path(installer)
        / "drive_c/Program Files/MALightingTechnology"
        / installer.install_dir_name
        / "bin"
    )
    return (bin_dir / "app_system.exe").exists()


def seed_terminal_config(installer: MaInstaller) -> None:
    cfg = (
        prefix_path(installer)
        / "drive_c/ProgramData/MALightingTechnology"
        / installer.install_dir_name
        / "terminalapp/config/terminal.cfg"
    )
    if cfg.exists():
        return
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_bytes(TERMINAL_CFG)


def _nix_compiler_env(env: dict[str, str]) -> dict[str, str]:
    """Preserve Nix compiler-wrapper environment variables for cross-compilers."""
    if not _is_nixos():
        return env
    merged = env.copy()
    for key, value in os.environ.items():
        if key.startswith("NIX_"):
            merged.setdefault(key, value)
    return merged


def _prebuilt_wintrust_dir() -> Path | None:
    """Return the prebuilt wintrust DLL directory if shipped with the package."""
    prebuilt = Path(__file__).resolve().parent.parent / "wintrust"
    if (prebuilt / "wintrust-native.dll").exists():
        return prebuilt
    return None


def _install_wintrust_dll(src: Path, dst: Path) -> None:
    if dst.exists() and not any(dst.parent.glob("wintrust.dll.winebak.*")):
        backup = dst.with_name(f"wintrust.dll.winebak.{_timestamp()}")
        import os
        os.chmod(dst, 0o644)
        shutil.copy2(dst, backup)
    import os
    if dst.exists():
        os.chmod(dst, 0o644)
        dst.unlink()
    shutil.copy2(src, dst)


def build_and_install_wintrust(prefix: Path, env: dict[str, str]) -> None:
    prebuilt = _prebuilt_wintrust_dir()
    if prebuilt is not None:
        dll64_path = prebuilt / "wintrust-native.dll"
        target = prefix / "drive_c/windows/system32/wintrust.dll"
        _install_wintrust_dll(dll64_path, target)
        dll32_path = prebuilt / "wintrust-native-x86.dll"
        if dll32_path.exists():
            wow64_target = prefix / "drive_c/windows/syswow64/wintrust.dll"
            _install_wintrust_dll(dll32_path, wow64_target)
        return

    if shutil.which("x86_64-w64-mingw32-gcc") is None:
        raise RuntimeError("x86_64-w64-mingw32-gcc is required to build wintrust.dll")
    build_dir = Path.home() / ".cache" / "winema3" / "wintrust"
    build_dir.mkdir(parents=True, exist_ok=True)
    c_path = build_dir / "wintrust_stub.c"
    def_path = build_dir / "wintrust_stub.def"
    c_path.write_text(WINTRUST_C, encoding="utf-8")
    def_path.write_text(WINTRUST_DEF, encoding="utf-8")

    # Build 64-bit
    dll64_path = build_dir / "wintrust-native.dll"
    run(
        ["x86_64-w64-mingw32-gcc", "-shared", "-o", str(dll64_path), str(c_path), str(def_path), "-Wl,--kill-at"],
        check=True,
        env=_nix_compiler_env(env),
    )
    target = prefix / "drive_c/windows/system32/wintrust.dll"
    _install_wintrust_dll(dll64_path, target)

    # Build and install 32-bit if compiler is available
    if shutil.which("i686-w64-mingw32-gcc"):
        dll32_path = build_dir / "wintrust-native-x86.dll"
        run(
            ["i686-w64-mingw32-gcc", "-shared", "-o", str(dll32_path), str(c_path), str(def_path), "-Wl,--kill-at"],
            check=True,
            env=env,
        )
        wow64_target = prefix / "drive_c/windows/syswow64/wintrust.dll"
        _install_wintrust_dll(dll32_path, wow64_target)


def _timestamp() -> str:
    import datetime as _dt

    return _dt.datetime.now().strftime("%Y%m%d%H%M%S")


def create_launchers(installer: MaInstaller) -> None:
    # When the NixOS module manages WineMA3 it ships the launchers and desktop
    # entry declaratively (so they're removed when the module is removed).
    # Writing them here would leave user-space artifacts that linger forever, so
    # skip all $HOME writes in that case.
    if os.environ.get("WINEMA3_MANAGED") == "1":
        return
    prefix = prefix_path(installer)
    bin_dir = prefix / "drive_c/Program Files/MALightingTechnology" / installer.install_dir_name / "bin"
    local_bin = Path.home() / ".local/bin"
    local_bin.mkdir(parents=True, exist_ok=True)
    is_nixos = _is_nixos()
    (local_bin / "gma3").write_text(_launcher(installer, "app_system.exe HOSTTYPE=onPC", "run", is_nixos=is_nixos), encoding="utf-8")
    (local_bin / "gma3term").write_text(_launcher(installer, 'app_terminal.exe "$@"', "terminal", is_nixos=is_nixos), encoding="utf-8")
    (local_bin / "gma3").chmod(0o755)
    (local_bin / "gma3term").chmod(0o755)
    _create_fish_helpers()
    _create_desktop_file(bin_dir)


def _launcher(installer: MaInstaller, wine_command: str, log_name: str, *, is_nixos: bool = False) -> str:
    prefix = f'${{XDG_DATA_HOME:-$HOME/.local/share}}/winema3/{installer.install_dir_name}'
    shebang = "#!/usr/bin/env bash"
    if is_nixos:
        shebang = "#!/usr/bin/env nix-shell\n#! nix-shell -i bash -p wineWow64Packages.full dxvk"
    return f"""{shebang}
set -u

export DISPLAY="${{DISPLAY:-:0}}"
export XDG_RUNTIME_DIR="${{XDG_RUNTIME_DIR:-/run/user/$(id -u)}}"
export DBUS_SESSION_BUS_ADDRESS="${{DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}}"
export WINEPREFIX="{prefix}"
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export MESA_GL_VERSION_OVERRIDE=4.2
export MESA_GLSL_VERSION_OVERRIDE=420
export WINEDLLOVERRIDES='wintrust=n,b;dxgi,d3d11=n'
export DXVK_LOG_LEVEL=info
export DXVK_LOG_PATH="$HOME/ma3-wine-tests/{installer.version}-clean/dxvk"

log="$HOME/malog-gma3-{installer.version}-{log_name}.log"
bin="$WINEPREFIX/drive_c/Program Files/MALightingTechnology/{installer.install_dir_name}/bin"

mkdir -p "$DXVK_LOG_PATH"
{{
  echo "=== gma3 {log_name} {installer.version} launch $(date -Is) ==="
  echo "WINEPREFIX=$WINEPREFIX"
  echo "DISPLAY=$DISPLAY"
  echo "LANG=$LANG LC_ALL=$LC_ALL"
  wine --version
}} >> "$log"

cd "$bin" || exit 1
{'systemctl --user start winema3-inhibit 2>/dev/null || true' if is_nixos else ''}
wine {wine_command}
rc=$?
{'systemctl --user stop winema3-inhibit 2>/dev/null || true' if is_nixos else ''}
echo "=== gma3 {log_name} {installer.version} exit rc=$rc $(date -Is) ===" >> "$log"
exit "$rc"
"""


def _create_fish_helpers() -> None:
    fish_dir = Path.home() / ".config/fish/functions"
    if shutil.which("fish") is None and not fish_dir.exists():
        return
    fish_dir.mkdir(parents=True, exist_ok=True)
    (fish_dir / "gma3.fish").write_text("function gma3\n    command $HOME/.local/bin/gma3 $argv\nend\n", encoding="utf-8")
    (fish_dir / "gma3term.fish").write_text("function gma3term\n    command $HOME/.local/bin/gma3term $argv\nend\n", encoding="utf-8")


def _create_desktop_file(bin_dir: Path) -> None:
    _remove_wine_ma_desktop_files()
    exec_command = _terminal_exec(bin_dir) or str(Path.home() / ".local/bin/gma3")
    icon = _desktop_icon()
    desktop = f"""[Desktop Entry]
Name=grandMA3
Exec={exec_command}
Type=Application
Terminal=false
StartupNotify=true
Comment=Start grandMA3 onPC via WineMA3
Path={bin_dir}
Icon={icon}
StartupWMClass=app_system.exe
Categories=AudioVideo;Utility;
X-GNOME-FullName=grandMA3
"""
    app_dir = Path.home() / ".local/share/applications"
    app_dir.mkdir(parents=True, exist_ok=True)
    app_file = app_dir / "grandMA3.desktop"
    old_app_file = app_dir / "grandMA3-onPC.desktop"
    old_app_file.unlink(missing_ok=True)
    _write_desktop_file(app_file, desktop)
    desktop_dir = Path.home() / "Desktop"
    if desktop_dir.exists():
        old_desktop_file = desktop_dir / "grandMA3 onPC.desktop"
        old_desktop_file.unlink(missing_ok=True)
        _write_desktop_file(desktop_dir / "grandMA3.desktop", desktop)

    if shutil.which("update-desktop-database"):
        run(["update-desktop-database", str(app_dir)])


def _write_desktop_file(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)
    if shutil.which("gio"):
        run(["gio", "set", str(path), "metadata::trusted", "true"])


def _terminal_exec(bin_dir: Path) -> str | None:
    launcher = str(Path.home() / ".local/bin/gma3")
    quoted_bin = _desktop_arg(str(bin_dir))
    quoted_launcher = _desktop_arg(launcher)
    candidates = [
        ("ptyxis", f"ptyxis --new-window --working-directory={quoted_bin} -- {quoted_launcher}"),
        ("gnome-terminal", f"gnome-terminal --working-directory={quoted_bin} -- {quoted_launcher}"),
        ("kgx", f"kgx --working-directory={quoted_bin} -- {quoted_launcher}"),
        ("gnome-console", f"gnome-console --working-directory={quoted_bin} -- {quoted_launcher}"),
        ("xfce4-terminal", f"xfce4-terminal --working-directory={quoted_bin} --command={quoted_launcher}"),
        ("konsole", f"konsole --workdir {quoted_bin} -e {quoted_launcher}"),
        ("mate-terminal", f"mate-terminal --working-directory={quoted_bin} -x {quoted_launcher}"),
        ("tilix", f"tilix --working-directory={quoted_bin} -e {quoted_launcher}"),
        ("alacritty", f"alacritty --working-directory {quoted_bin} -e {quoted_launcher}"),
        ("xterm", f"xterm -e {quoted_launcher}"),
    ]
    for binary, command in candidates:
        if shutil.which(binary):
            return command
    return None


def _desktop_arg(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _desktop_icon() -> str:
    if _icon_theme_has("8254_app_system.0"):
        return "8254_app_system.0"
    if _install_fallback_icon():
        return "winema3-grandma3"
    return "applications-graphics"


def _install_fallback_icon() -> bool:
    source = Path(__file__).resolve().parent.parent / "assets/winema3-grandma3.svg"
    if not source.exists():
        return False
    target = Path.home() / ".local/share/icons/hicolor/scalable/apps/winema3-grandma3.svg"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    icon_theme = Path.home() / ".local/share/icons/hicolor"
    if shutil.which("gtk-update-icon-cache") and (icon_theme / "index.theme").exists():
        run(["gtk-update-icon-cache", "-q", str(icon_theme)])
    return True


def _icon_theme_has(icon_name: str) -> bool:
    icon_dirs = [
        Path.home() / ".local/share/icons",
        Path.home() / ".icons",
        Path("/usr/share/icons"),
        Path("/usr/local/share/icons"),
    ]
    suffixes = (".png", ".svg", ".xpm")
    for icon_dir in icon_dirs:
        if not icon_dir.exists():
            continue
        for suffix in suffixes:
            if any(icon_dir.rglob(f"{icon_name}{suffix}")):
                return True
    return False


def _remove_wine_ma_desktop_files() -> None:
    app_dir = Path.home() / ".local/share/applications"
    wine_programs = app_dir / "wine/Programs"
    if wine_programs.exists():
        for desktop_file in wine_programs.rglob("*.desktop"):
            try:
                text = desktop_file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if "grandMA3" in text or "MALightingTechnology" in text or "MA Lighting" in text:
                desktop_file.unlink(missing_ok=True)

        for directory in sorted(wine_programs.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            if directory.is_dir():
                try:
                    directory.rmdir()
                except OSError:
                    pass
