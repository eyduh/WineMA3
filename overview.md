# WineMA3 Python Modules Overview

WineMA3 is a Python-based Wine installer for running grandMA3 onPC (professional lighting console software from MA Lighting) on Linux. The project is organized into top-level entry-point scripts and a `wine_ma3` package that handles system detection, installer discovery, Wine prefix setup, networking, power management, and CLI orchestration.

| File | Module | Description/Role |
|------|--------|------------------|
| `install.py` | (entry point) | Rich-powered Wine-only grandMA3 onPC installer. Ensures `python-rich` is installed, then delegates to `wine_ma3.cli`. |
| `probe.py` | (entry point) | Prints WineMA3 system probe information (OS, GPU, Wine, networking, etc.) without installing anything. |
| `uninstall.py` | (entry point) | Removes WineMA3 launchers and optionally deletes the Wine prefix(es). |
| `wine_ma3/__init__.py` | `wine_ma3` | Package initializer. Declares the package and its version (`0.1.0`). |
| `wine_ma3/cli.py` | `wine_ma3.cli` | Rich CLI orchestrator. Handles installer selection, system probe display, package installation, networking fixes, power-saving setup, and drives the overall installation flow. |
| `wine_ma3/installers.py` | `wine_ma3.installers` | grandMA3 installer discovery. Finds EXE/ZIP installers in `ma3onpcinstaller/`, infers versions, and extracts archives when needed. |
| `wine_ma3/networking.py` | `wine_ma3.networking` | Network fix helpers for MA-Net under Wine. Detects firewalls (UFW, firewalld, nftables), applies port rules, sets `cap_net_raw` on `wineserver`, and handles NixOS networking guidance. |
| `wine_ma3/power.py` | `wine_ma3.power` | Power saving and idle blanking controls for MA workstations. Masks systemd sleep targets and installs user-level scripts/services to disable screensaver, DPMS, and desktop idle settings for GNOME, XFCE, and KDE. |
| `wine_ma3/system.py` | `wine_ma3.system` | System probing and command helpers. Detects Linux distro, probes CPU/GPU/virtualization, runs commands, and collects system state for the installer. |
| `wine_ma3/wine_setup.py` | `wine_ma3.wine_setup` | Wine prefix, patch, and launcher generation. Creates the Wine prefix, installs DXVK, builds and installs the `wintrust.dll` stub, seeds terminal config, and generates `gma3`/`gma3term` launcher scripts and `.desktop` files. |
