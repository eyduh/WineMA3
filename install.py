#!/usr/bin/env python3
"""Rich-powered Wine-only grandMA3 onPC installer."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent


def _read_os_release() -> dict[str, str]:
    data: dict[str, str] = {}
    path = Path("/etc/os-release")
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value.strip().strip('"')
    return data


def _rich_package_command() -> list[str] | None:
    os_release = _read_os_release()
    distro_ids = " ".join(
        [os_release.get("ID", ""), os_release.get("ID_LIKE", "")]
    ).lower()
    if any(x in distro_ids for x in ("arch", "cachyos", "manjaro")):
        return ["sudo", "pacman", "-S", "--needed", "--noconfirm", "python-rich"]
    if any(x in distro_ids for x in ("debian", "ubuntu")):
        return ["sudo", "apt-get", "install", "-y", "python3-rich"]
    if "fedora" in distro_ids or "rhel" in distro_ids:
        return ["sudo", "dnf", "install", "-y", "python3-rich"]
    if any(x in distro_ids for x in ("opensuse", "suse")):
        return ["sudo", "zypper", "install", "-y", "python3-rich"]
    return None


def _ensure_rich() -> None:
    if importlib.util.find_spec("rich") is not None:
        return
    command = _rich_package_command()
    print("python-rich is required for this installer.")
    if command is None:
        print("Unsupported distro for automatic python-rich installation.")
        print("Install Rich with your distro package manager, then rerun install.py.")
        raise SystemExit(2)
    print("Suggested command:")
    print("  " + " ".join(command))
    try:
        answer = input("Install python-rich now? [y/N] ").strip().lower()
    except EOFError:
        print("No interactive input available; install python-rich and rerun install.py.")
        raise SystemExit(2) from None
    if answer not in {"y", "yes"}:
        raise SystemExit(2)
    subprocess.run(command, check=True)
    os.execv(sys.executable, [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])


def main() -> int:
    if any(arg in {"-h", "--help"} for arg in sys.argv[1:]):
        print(
            "usage: install.py [-h] [--noinstall]\n\n"
            "Install grandMA3 onPC into a Wine prefix.\n\n"
            "options:\n"
            "  -h, --help   show this help message and exit\n"
            "  --noinstall  skip running the MA installer EXE and only refresh Wine/DXVK/wintrust/launchers"
        )
        return 0
    _ensure_rich()
    from wine_ma3.cli import main as cli_main

    return cli_main(REPO_ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
