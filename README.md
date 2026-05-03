# WineMA3

WineMA3 is a Wine-only installer for running the Windows grandMA3 onPC build on
Linux.

This project does **not** use the native grandMA3 Linux installer. It installs the
Windows onPC build into a dedicated Wine prefix and sets everything up for you.

## Supported Systems

First-version target distros:

- Arch / CachyOS / Manjaro-like
- Debian / Ubuntu-like
- Fedora-like
- openSUSE-like

Unsupported or experimental:

- Alpine / musl
- Flatpak or Snap Wine
- immutable/containerized systems
- non-mainstream package managers

## Installer File

Download the Windows grandMA3 onPC installer from MA Lighting and place it here:

```text
ma3onpcinstaller/
```

ZIP and direct EXE installers are both supported:

```text
ma3onpcinstaller/grandMA3_onPC_win_v2.3.2.0.zip
ma3onpcinstaller/grandMA3_onPC_win_v2.3.2.0.exe
```

The installer scans `ma3onpcinstaller/*.exe` and `ma3onpcinstaller/*.zip`. ZIP
files are probed with Python's built-in ZIP reader. If a ZIP contains an EXE,
the installer extracts the selected EXE into `ma3onpcinstaller/.extracted/` and
uses that extracted EXE for the Wine install. If multiple installer candidates
are present, it shows a Rich selection table and asks which one to install.

## Usage

Run:

```bash
python3 install.py
```

If Python Rich is missing, `install.py` asks to install it through the native
package manager (`python-rich` or `python3-rich`) and then restarts itself.

When debugging an already-installed prefix, skip rerunning the MA installer EXE:

```bash
python3 install.py --noinstall
```

This still refreshes Wine bootstrap state, DXVK, the wintrust override, and
launchers.

Probe without installing:

```bash
python3 probe.py
```

Uninstall launchers and optionally Wine prefixes:

```bash
python3 uninstall.py
```

## What It Installs

The installer creates a versioned Wine prefix, for example:

```text
~/.wine-gma2320
```

It installs:

- Wine prefix via `wineboot -u`
- selected grandMA3 Windows EXE using `/S`
- DXVK via `winetricks -q dxvk` or Debian's `dxvk-setup install`
- prefix-local native `wintrust.dll` stub
- Wine override `*wintrust = native,builtin`
- `~/.local/bin/gma3`
- `~/.local/bin/gma3term`
- fish helpers when fish exists
- desktop file when a known terminal emulator exists

## Launching

Start onPC:

```bash
gma3
```

Open app_terminal:

```bash
gma3term
```

Inside `gma3term`, `help` should show:

```text
SYSMON [ip]
SYSNOW [ip]
SHELL [ip]
CMDLINE [ip]
```

Do not pipe `gma3term` through `tee` or similar tools. `app_terminal.exe` needs
direct interactive terminal I/O or typed text may not appear.

## Networking Notes

MA-Net3 uses UDP multicast on port `30020`, commonly in the `236.4.x.x` range.
Web Remote uses TCP `8080`. Wine MA-Net networking may need:

```bash
sudo setcap cap_net_raw=ep "$(command -v wineserver)"
```

The installer asks before applying this.

If UFW, firewalld, nftables.service, or netfilter-persistent is active, the
installer asks whether to disable host firewalls for a trusted LAN-only MA VM,
apply MA-Net rules where the backend supports it, or skip firewall changes. It
never disables a firewall silently.

## Power And Display Management

The installer also asks to disable OS sleep and desktop idle power saving. When
accepted, it masks systemd sleep targets, writes a systemd sleep.conf drop-in,
writes an Xorg no-blanking/DPMS drop-in, and installs a per-user autostart
helper that applies `xset`, GNOME `gsettings`, XFCE `xfconf-query`, and KDE
PowerDevil/screen-locker settings at login.

This is intended for dedicated MA workstations and show-control VMs where the
application must stay visible and running without a screen blank, display power
off, suspend, or lock-screen login prompt interrupting operation. The installer
does not install third-party caffeine-style tools; it applies the native
systemd and desktop settings directly and reapplies session-local display
settings on desktop login.

The current controls cover:

- systemd suspend, sleep, hibernate, hybrid-sleep, and suspend-then-hibernate
- X11 screen blanking, screensaver timeout, and DPMS display power-off
- GNOME automatic screen blank, screen lock, idle activation, dimming, and
  inactive sleep behavior
- XFCE screen blanking, DPMS, presentation mode, screensaver, and lock settings
- KDE screen locker and PowerDevil display/suspend profile settings

## Proxmox VM Notes

The system probe checks for KVM/Proxmox-style VMs and reports a warning when the
guest appears to be using generic virtual CPU or non-VirGL graphics. For
grandMA3 onPC under Wine in a Proxmox VM, use:

```text
CPU type: host
GPU/display: VirGL
```

Generic KVM/QEMU CPU types have caused Wine/grandMA3 issues in testing.

## Known Constraints

- Official MA onPC support is Windows/macOS; Wine on Linux is unofficial.
- The tested target is grandMA3 onPC `2.3.2.0`.
- `app_system.exe HOSTTYPE=onPC` is the launcher path; direct `app_gma3.exe` was
  not the working route in the reference setup.
- Use a real terminal/TTY. Detached `nohup`-style launch can fail with
  `utf8_codepage not supported for input`.
