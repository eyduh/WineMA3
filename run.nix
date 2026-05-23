#!/usr/bin/env nix-shell
#! nix-shell -i bash -p "python3.withPackages (ps: [ ps.rich ])" wineWow64Packages.full winetricks dxvk mingw-w64 zenity rsync gnutar zstd curl wget coreutils gnused gnugrep busybox

# WineMA3 — run the Python installer from a pure Nix shell.
# Usage: ./run.nix [--noinstall | probe | uninstall]
# Or:    nix-shell run.nix --run "python3 install.py --noinstall"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Export DXVK path for NixOS manual install fallback
for p in $(echo "$PATH" | tr ':' '\n'); do
    if [[ "$p" == */dxvk* ]] && [[ -d "$p/x64" ]]; then
        export DXVK_PATH="$p"
        break
    fi
done

if [[ "${1:-}" == "probe" ]]; then
    exec python3 "$REPO_ROOT/probe.py"
elif [[ "${1:-}" == "uninstall" ]]; then
    exec python3 "$REPO_ROOT/uninstall.py"
else
    exec python3 "$REPO_ROOT/install.py" "$@"
fi
