#!/usr/bin/env python3
"""Remove WineMA3 launchers and optionally the Wine prefix."""

from __future__ import annotations

import shutil
from pathlib import Path


def ask(prompt: str) -> bool:
    return input(f"{prompt} [y/N] ").strip().lower() in {"y", "yes"}


def main() -> int:
    home = Path.home()
    paths = [
        home / ".local/bin/gma3",
        home / ".local/bin/gma3term",
        home / ".config/fish/functions/gma3.fish",
        home / ".config/fish/functions/gma3term.fish",
        home / ".local/share/applications/grandMA3-onPC.desktop",
        home / "Desktop/grandMA3 onPC.desktop",
    ]
    for path in paths:
        if path.exists() or path.is_symlink():
            print(f"Removing {path}")
            path.unlink()

    prefixes = sorted(home.glob(".wine-gma*"))
    if prefixes:
        print("\nWine prefixes:")
        for idx, prefix in enumerate(prefixes, start=1):
            print(f"  {idx}. {prefix}")
        if ask("Remove these Wine prefixes too?"):
            for prefix in prefixes:
                print(f"Removing {prefix}")
                shutil.rmtree(prefix)

    print("Uninstall complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

