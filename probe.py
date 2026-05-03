#!/usr/bin/env python3
"""Print WineMA3 system probe information without installing anything."""

from __future__ import annotations

from wine_ma3.system import probe


def main() -> int:
    data = probe()
    for key, value in data.items():
        print(f"== {key} ==")
        print(value or "missing")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

