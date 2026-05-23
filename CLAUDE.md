# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WineMA3 is a Wine-only installer for running grandMA3 onPC (professional lighting console software from MA Lighting) on Linux. It installs the Windows build into a dedicated Wine prefix with DXVK and custom wintrust.dll stub.

## Commands

```bash
# Run the installer
python3 install.py

# Skip MA installer (refresh Wine/DXVK/wintrust/launchers only)
python3 install.py --noinstall

# System probe without installing
python3 probe.py

# Uninstall launchers and optionally Wine prefixes
python3 uninstall.py
```

## Architecture

**Entry points:**
- `install.py` - Ensures Python Rich dependency, then calls `wine_ma3.cli.main()`
- `probe.py` - Prints system probe data
- `uninstall.py` - Removes launchers and prefixes

**wine_ma3 package:**
- `cli.py` - Rich CLI orchestrator (installer selection, prompts, installation flow)
- `system.py` - Distro detection, system probing (CPU/GPU/VM detection), command execution
- `installers.py` - Discovers grandMA3 installers (EXE/ZIP in `ma3onpcinstaller/`), version inference
- `wine_setup.py` - Wine prefix creation, DXVK setup, wintrust.dll stub build/install, launcher generation (`gma3`, `gma3term`, fish helpers, desktop files)
- `networking.py` - Firewall detection (UFW, firewalld), wineserver capabilities, MA-Net port rules
- `power.py` - Systemd sleep masking, Xorg DPMS config, desktop idle settings for GNOME/XFCE/KDE

## Key Design Points

- **Distro-specific packages**: `system.py:94-144` defines packages for Arch/Debian/Fedora/openSUSE
- **Wine prefix location**: `~/.wine-gma<version>` (e.g., `.wine-gma2320`)
- **wintrust.dll stub**: Built with `x86_64-w64-mingw32-gcc` to bypass code signing checks
- **Launcher scripts**: Generated in `~/.local/bin/` with Wine env vars for OpenGL/DXVK
- **Power management**: Masks systemd sleep targets and installs autostart script for desktop idle settings

## Supported Distros

Arch/CachyOS/Manjaro, Debian/Ubuntu, Fedora/RHEL, openSUSE. Alpine/musl and Flatpak/Snap Wine are not supported.