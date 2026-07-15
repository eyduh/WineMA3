# WineMA3 (Nix)

A Nix flake and NixOS module for running the Windows grandMA3 onPC build on
Linux under Wine.

This repository packages the WineMA3 installer as a flake and adds a NixOS
module that wires up the launcher, firewall, `wineserver` capabilities, and
optional sleep inhibition declaratively. It does **not** use the native
grandMA3 Linux installer — it installs the Windows onPC build into a dedicated
Wine prefix.

> **Upstream / original project:** <https://github.com/kinglevel/WineMA3>
>
> This fork focuses on the Nix packaging. For the portable Python installer and
> its support matrix across other distros, see upstream. Everything below is
> Nix-specific.

## Requirements

- Nix with flakes enabled (`experimental-features = nix-command flakes`).
- `x86_64-linux` (the only supported system).
- The Windows grandMA3 onPC installer (EXE or ZIP) from MA Lighting — it is not
  redistributed here and is supplied at runtime, never copied into the Nix
  store.

Two supported setups:

- **NixOS** — import the [NixOS module](#nixos-module) for a fully declarative
  launcher, firewall, `wineserver` capabilities, and sleep inhibition.
- **Non-NixOS with Nix** (any distro, or the Nix package manager on macOS-less
  Linux hosts) — install the package into your Nix profile and let the installer
  handle firewall/capabilities/power itself. See
  [Non-NixOS hosts](#non-nixos-hosts).

## Flake Outputs

| Output | Description |
|--------|-------------|
| `packages.default` / `packages.winema3` | The WineMA3 package (`winema3-install`, `winema3-probe`, `winema3-uninstall` wrappers with Wine, DXVK, mingw stubs, etc. baked into `PATH`). |
| `apps.default` / `apps.install` | Runs `winema3-install`. |
| `apps.probe` | Runs `winema3-probe` (system probe, installs nothing). |
| `apps.uninstall` | Runs `winema3-uninstall`. |
| `devShells.default` | Dev shell with Python + Rich, Wine, winetricks, DXVK, mingw cross-compilers, and the runtime tooling. |
| `overlays.default` | Adds `pkgs.winema3`. |
| `nixosModules.default` / `nixosModules.winema3` | The `programs.winema3` NixOS module. |

## Running The Installer

Place the MA Lighting installer where the wrapper looks for it. The
`winema3-install` wrapper resolves the installer directory as follows:

1. `$WINEMA3_REPO_ROOT` if set,
2. otherwise `$PWD` when `./ma3onpcinstaller/` exists,
3. otherwise `~/.local/share/winema3/` (created for you).

So the simplest path is to drop the EXE/ZIP into that directory and run:

```bash
mkdir -p ~/.local/share/winema3/ma3onpcinstaller
cp grandMA3_onPC_win_v2.3.2.0.zip ~/.local/share/winema3/ma3onpcinstaller/

nix run github:eyduh/WineMA3        # or: nix run .#install from a clone
```

Both ZIP and direct EXE installers are supported; ZIPs are probed and the
selected EXE is extracted automatically.

Probe the system without installing:

```bash
nix run github:eyduh/WineMA3#probe
```

Remove launchers and optionally the Wine prefixes:

```bash
nix run github:eyduh/WineMA3#uninstall
```

### Dev shell

For hacking on the installer with all runtime dependencies on `PATH`:

```bash
nix develop
```

## Non-NixOS hosts

On any Linux distro that has Nix installed (but is **not** running NixOS), the
NixOS module does not apply — use the package directly. Install it into your
profile so the wrappers land on `PATH`:

```bash
nix profile install github:eyduh/WineMA3        # winema3-install, -probe, -uninstall

# or run once without installing:
nix run github:eyduh/WineMA3
```

Then run the installer as in [Running The Installer](#running-the-installer).
Because there is no NixOS module here, the installer does the runtime setup that
the module would otherwise do declaratively — it detects your firewall backend
(UFW, firewalld, nftables, netfilter-persistent), offers to apply MA-Net rules,
offers to grant `wineserver` `cap_net_raw`, and offers the power/idle settings —
each behind a prompt, nothing applied silently. It generates
`~/.local/bin/gma3` and `~/.local/bin/gma3term` launchers (and a `.desktop`
entry when a known terminal emulator is present).

Notes for non-NixOS:

- `wineserver` here is a Nix store path, so the `cap_net_raw` capability is set
  on the store binary. It works, but re-run the installer (or `setcap`) if the
  Wine package is garbage-collected or updated to a new store path.
- Uninstall with `nix run github:eyduh/WineMA3#uninstall` (removes launchers and
  optionally the prefixes), then `nix profile remove` the package.

## NixOS Module

> NixOS only. On other distros with Nix, see [Non-NixOS hosts](#non-nixos-hosts).

Prefer the module on NixOS — it owns the launcher, desktop entry, firewall
rules, `wineserver` capability wrapper, and (optionally) sleep inhibition, so
removing the module leaves nothing behind in `$HOME`.

```nix
{
  inputs.winema3.url = "github:eyduh/WineMA3";

  # In your NixOS configuration:
  imports = [ winema3.nixosModules.default ];

  programs.winema3 = {
    enable = true;
    launchMode = "on-demand";   # "always" | "on-demand"
    openFirewall = true;
    keepAwake = false;
  };
}
```

Add the flake to your `inputs` and pass it through to your system (`specialArgs`
or the `nixpkgs.lib.nixosSystem` modules list) so `winema3.nixosModules.default`
is in scope.

You still install the MA3 onPC build once with `winema3-install` (the module
puts the installer package on `PATH`); the module manages everything around the
runtime.

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `programs.winema3.enable` | bool | `false` | Enable the installer package and runtime support. |
| `programs.winema3.package` | package | `pkgs.winema3` | The WineMA3 package to use. |
| `programs.winema3.launchMode` | `"always"` \| `"on-demand"` | `"on-demand"` | When firewall ports open and sleep inhibition is active (see below). |
| `programs.winema3.openFirewall` | bool | `true` | Open MA-Net ports: UDP `30020`, TCP `8080` and `30022`–`30040`. |
| `programs.winema3.wineserver.capNetRaw` | bool | `true` | Wrap `wineserver` with `cap_net_raw=ep` for MA-Net multicast. |
| `programs.winema3.keepAwake` | bool | `false` | Inhibit sleep and suppress idle/screen-blanking while grandMA3 runs (**disables** power saving so a show never suspends or blanks mid-cue). |

### Launch modes

- **`always`** — ports are static declarative `networking.firewall` rules and,
  with `keepAwake`, the inhibit service starts at login and the power-settings
  script runs on every graphical session. Suited to a dedicated grandMA3
  workstation.
- **`on-demand`** — a system service opens the ports (and, with `keepAwake`,
  starts inhibition and applies power settings) only while grandMA3 is running,
  tearing everything down on exit. The shipped **grandMA3 (Wine)** menu entry is
  wrapped with `winema3-wrap` so launching from the menu handles this
  automatically. A polkit rule lets `wheel` users manage the firewall unit
  without a password prompt.

> **nftables note:** `on-demand` `openFirewall` edits the live `nixos-fw`
> chain at runtime and therefore requires the **iptables** firewall backend. An
> assertion enforces this — either set `networking.nftables.enable = false`, or
> use `launchMode = "always"` (static rules) on nftables hosts.

## Launching

The module ships a launcher named **`gma3-wine`** (named so it never collides
with a native `gma3` launcher). It discovers the newest Wine prefix under
`$XDG_DATA_HOME/winema3` (default `~/.local/share/winema3`) and starts onPC:

```bash
gma3-wine
```

Or launch **grandMA3 (Wine)** from your application menu. In `on-demand` mode
the menu entry runs through `winema3-wrap`, which opens the MA-Net ports for the
session — launching this way is required for the console to reach the PC.

The desktop entry runs in a terminal on purpose: launching from a
`Terminal=false` entry lands the process in a transient KDE app scope whose
control-group teardown reaps the onPC console shortly after start.

## Networking

MA-Net3 uses UDP multicast on port `30020` (commonly `236.4.x.x`); Web Remote
uses TCP `8080`. On NixOS the module handles both:

- `openFirewall` opens the required ports (statically in `always`, dynamically
  in `on-demand`).
- `wineserver.capNetRaw` grants `wineserver` `cap_net_raw` via
  `security.wrappers`, needed for MA-Net multicast under Wine.

## Proxmox / KVM VM Notes

`winema3-probe` warns when the guest looks like a generic virtual CPU or
non-VirGL graphics. For grandMA3 onPC under Wine in a Proxmox VM use:

```text
CPU type: host
GPU/display: VirGL
```

Generic KVM/QEMU CPU types have caused Wine/grandMA3 issues in testing.

## Known Constraints

- Official MA onPC support is Windows/macOS; Wine on Linux is unofficial.
- The tested target is grandMA3 onPC `2.3.2.0`.
- `app_system.exe HOSTTYPE=onPC` is the launcher path (overridable via
  `WINEMA3_APP`); direct `app_gma3.exe` was not the working route.
- Use a real terminal/TTY for `app_terminal.exe` — detached launches can fail
  with `utf8_codepage not supported for input`.
