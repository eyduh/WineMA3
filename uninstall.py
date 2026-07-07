#!/usr/bin/env python3
"""Remove WineMA3 user-space artifacts and optionally the Wine prefix.

Cleans up everything the runtime installer may have written to $HOME (launchers,
desktop entries, fish helpers, icons) — including artifacts left by older
versions — so nothing lingers after the module or install is removed.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path


def _xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local/share"))


def ask(prompt: str) -> bool:
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in {"y", "yes"}
    except EOFError:
        return False


def main() -> int:
    home = Path.home()
    data = _xdg_data_home()

    # Launchers, desktop entries (current + legacy names), fish helpers, icons.
    paths = [
        home / ".local/bin/gma3",
        home / ".local/bin/gma3term",
        home / ".config/fish/functions/gma3.fish",
        home / ".config/fish/functions/gma3term.fish",
        data / "applications/grandMA3.desktop",
        data / "applications/grandMA3-onPC.desktop",
        home / "Desktop/grandMA3.desktop",
        home / "Desktop/grandMA3 onPC.desktop",
        data / "icons/hicolor/scalable/apps/winema3-grandma3.svg",
    ]
    for path in paths:
        if path.exists() or path.is_symlink():
            print(f"Removing {path}")
            path.unlink()

    # Wine prefixes: current XDG location and the legacy dot-dir location.
    prefixes = sorted((data / "winema3").glob("gma3_*")) if (data / "winema3").exists() else []
    prefixes += sorted(home.glob(".wine-gma*"))
    if prefixes:
        print("\nWine prefixes (regenerable):")
        for prefix in prefixes:
            print(f"  {prefix}")
        if ask("Remove these Wine prefixes too?"):
            for prefix in prefixes:
                print(f"Removing {prefix}")
                shutil.rmtree(prefix, ignore_errors=True)

    print(
        "\nUninstall complete. Show data under "
        f"{data / 'grandMA3'} (shows, backups, library) was kept — delete it "
        "yourself if you no longer need it."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
