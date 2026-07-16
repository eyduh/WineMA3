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

Supported setups:

- **NixOS** — import the [NixOS module](#nixos-module) for a fully declarative
  launcher, firewall, `wineserver` capabilities, and sleep inhibition.
- **Home Manager** — import the [Home Manager module](#home-manager-module) for a
  per-user launcher, menu entry, and keep-awake behaviour. Firewall and
  `wineserver` capabilities need root, so they're handled by the NixOS module or
  the installer's prompts.
- **Non-NixOS with Nix** (any distro) — install the package into your Nix
  profile and let the installer handle firewall/capabilities/power itself. See
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

### Setup, end to end

Getting from nothing to a running console is a **two-phase** process: the module
is declarative Nix, but the Wine prefix is populated once by an imperative
installer run, and you launch with an ordinary command. In order:

1. **Get the installer** (not Nix). Download the Windows grandMA3 onPC EXE/ZIP
   from MA Lighting and drop it in the installer directory:
   ```bash
   mkdir -p ~/.local/share/winema3/ma3onpcinstaller
   cp grandMA3_onPC_win_v*.zip ~/.local/share/winema3/ma3onpcinstaller/
   ```
2. **Enable the module** (Nix). Add the `programs.winema3` block above and
   rebuild:
   ```bash
   sudo nixos-rebuild switch --flake .#<host>
   ```
   This installs the launcher, desktop entry, firewall rules, and the
   `winema3-install` package on `PATH` — but does **not** create the prefix yet.
3. **Populate the Wine prefix** (Nix, one time). Run the installer once; it
   creates the prefix, installs onPC, DXVK, and the wintrust stub:
   ```bash
   winema3-install
   ```
   The module sets `WINEMA3_MANAGED=1`, so this writes nothing into `$HOME` —
   it only fills the prefix under `~/.local/share/winema3/`.
4. **Launch** (not Nix). `gma3-wine`, or the **grandMA3 (Wine)** menu entry.

Re-run step 3 only to upgrade onPC or repair the prefix; steps 2 and 4 are the
everyday path.

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

## Home Manager Module

A Home Manager module (`homeModules.default`) is available for managing the
launcher per-user without NixOS. Because Home Manager only manages user-scope
state, it is a **subset** of the NixOS module: it handles the launcher, menu
entry, and keep-awake behaviour, but **not** the firewall or `wineserver`
capabilities (those require root).

```nix
{
  inputs.winema3.url = "github:eyduh/WineMA3";

  # In your Home Manager configuration:
  imports = [ winema3.homeModules.default ];

  programs.winema3 = {
    enable = true;
    launchMode = "on-demand";   # "always" | "on-demand"
    keepAwake = false;
  };
}
```

### Wiring the input into standalone Home Manager

The `imports` line above assumes the `winema3` flake is in scope where you write
it. With **standalone** Home Manager (a `homeConfigurations` flake), the module
lives in a `homeManagerConfiguration` call, and there are two ways to get the
flake to it. Pick one — mixing them up causes an `infinite recursion` error.

**Simplest — import directly in the flake's `modules` list** (the input is
already in scope there):

```nix
# flake.nix
homeConfigurations."<host>" = home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    winema3.homeModules.default
    ./winema3.nix               # your per-host settings file (no import needed)
  ];
};
```
```nix
# winema3.nix — pure settings, no winema3 arg, no import:
{ ... }:
{
  programs.winema3 = { enable = true; launchMode = "on-demand"; keepAwake = false; };
}
```

**Or — keep the import in a separate file** that takes the flake as an arg. That
arg **must** be passed via `extraSpecialArgs`, not left to `_module.args`:

```nix
# flake.nix
homeConfigurations."<host>" = home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  extraSpecialArgs = { inherit winema3; };   # required — see note below
  modules = [ ./winema3.nix ];
};
```
```nix
# winema3.nix
{ winema3, ... }:
{
  imports = [ winema3.homeModules.default ];
  programs.winema3 = { enable = true; launchMode = "on-demand"; keepAwake = false; };
}
```

> **Why `extraSpecialArgs`?** `imports` is resolved *before* `config` exists.
> `specialArgs` are available at that stage; ordinary module args
> (`_module.args`) are not — resolving one requires `config`, so referencing such
> an arg inside `imports` creates a cycle and Home Manager aborts with
> `infinite recursion encountered … you probably reference 'config' in
> 'imports'`. Passing the flake through `extraSpecialArgs` avoids that.

What the Home Manager module reproduces vs. the NixOS module:

| Functionality | Home Manager | NixOS |
|---|:---:|:---:|
| Install package + `gma3-wine` launcher | ✅ | ✅ |
| **grandMA3 (Wine)** menu entry | ✅ | ✅ |
| `WINEMA3_MANAGED` marker | ✅ | ✅ |
| `keepAwake` sleep inhibition (user service) | ✅ | ✅ |
| `keepAwake` idle/DPMS/screensaver suppression | ✅ | ✅ |
| `launchMode` scoping of the above | ✅ | ✅ |
| `openFirewall` (MA-Net ports) | ❌ needs root | ✅ |
| `wineserver` `cap_net_raw` | ❌ needs root | ✅ |
| polkit rule for the firewall unit | ❌ needs root | ✅ |

Options are the same as the NixOS module minus the privileged ones —
`enable`, `package`, `launchMode`, and `keepAwake` (there is no `openFirewall`
or `wineserver.capNetRaw`). Enabling it emits a `warning` reminding you that
MA-Net networking must be handled elsewhere.

### OpenGL/Vulkan on non-NixOS (automatic nixGL)

On a non-NixOS host the Nix-built wine can't reach the system GPU driver, so
grandMA3 aborts at launch with **"Application needs opengl >= 4.3"**. The Home
Manager module handles this automatically: when **`targets.genericLinux.enable =
true`** (Home Manager's standard "not on NixOS" switch), `gma3-wine` routes wine
through [nixGL](https://github.com/nix-community/nixGL) — `nixGLIntel` for
OpenGL (the Mesa wrapper, which also covers AMD `radeonsi`/RADV despite the name)
and `nixVulkanIntel` for the Vulkan ICD that DXVK needs. nixGL is bundled as a
flake input, so there's nothing extra to configure beyond enabling
`targets.genericLinux`.

```nix
targets.genericLinux.enable = true;   # required on non-NixOS for GL/Vulkan
programs.winema3.enable = true;
```

On NixOS the wrapper is omitted (the system provides `/run/opengl-driver`), so
nixGL is never pulled into the closure.

For the networking side, pair it with:

- the [NixOS module](#nixos-module) or a few lines of `networking.firewall` /
  `security.wrappers` in your system config (Home Manager on NixOS), or
- the `winema3-install` runtime prompts, which apply firewall rules and
  `setcap cap_net_raw` via sudo (Home Manager on another distro — see
  [Non-NixOS hosts](#non-nixos-hosts)).

### Setup, end to end

Same **two-phase** shape as the NixOS module — declarative Home Manager to place
the launcher, then a one-time imperative installer run, then launch. In order:

1. **Get the installer** (not Nix). Download the onPC EXE/ZIP from MA Lighting:
   ```bash
   mkdir -p ~/.local/share/winema3/ma3onpcinstaller
   cp grandMA3_onPC_win_v*.zip ~/.local/share/winema3/ma3onpcinstaller/
   ```
2. **Enable the module** (Nix). Add the `programs.winema3` block above and
   activate:
   ```bash
   home-manager switch --flake .#<you>
   ```
   This puts `gma3-wine`, the menu entry, and the `winema3-install` package on
   your PATH.
3. **Populate the Wine prefix** (Nix, one time). Run the installer with
   `WINEMA3_MANAGED=1` set explicitly — this guarantees it writes nothing into
   `$HOME` (no stray `~/.local/bin/gma3`), regardless of which shell you launch
   from:
   ```bash
   WINEMA3_MANAGED=1 winema3-install
   ```
   On a non-NixOS host it will also prompt for the firewall rules and
   `setcap cap_net_raw` (the parts Home Manager can't do declaratively) — accept
   them.
4. **Launch** (not Nix). `gma3-wine`, or the **grandMA3 (Wine)** menu entry.

> **Why `WINEMA3_MANAGED=1` in step 3?** The module sets it via
> `home.sessionVariables`, but that only loads in shells that source
> `hm-session-vars.sh`. If you run the installer from a shell that hasn't, it
> thinks it's unmanaged and writes `~/.local/bin/gma3` — a launcher that calls
> bare `wine`, which isn't on your PATH under Nix (wine lives in the store, only
> `gma3-wine` references it by full path). Setting the var inline avoids that.
> If you already have stray launchers, remove them:
> `rm -f ~/.local/bin/gma3 ~/.local/bin/gma3term ~/.local/share/applications/grandMA3*.desktop`.

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

## Prebuilt Prefix (unfree, private cache)

To avoid re-running the installer on every device, the flake can build the
**fully-installed onPC Wine prefix once** and let your other machines pull it
from a binary cache — the same idea as caching any package.

- `packages.onpc-prefix` (`nix/onpc-prefix.nix`) runs the onPC installer + DXVK +
  wintrust headlessly at build time and captures the finished prefix as a store
  path.
- `packages.winema3-install-prefix` copies that store prefix into
  `~/.local/share/winema3/` on a device (`nix run .#winema3-install-prefix`),
  which is all a device then needs before `gma3-wine`.

Two hard rules, modelled on nixpkgs' `davinci-resolve`:

1. **Unfree + you supply the installer.** grandMA3 onPC is proprietary MA
   Lighting software. `onpc-prefix` is marked `license = lib.licenses.unfree`
   (build requires `NIXPKGS_ALLOW_UNFREE=1` / `nixpkgs.config.allowUnfree`), and
   the installer comes in via `requireFile` — it is never redistributed by this
   flake. Provide it once:
   ```bash
   nix hash file grandMA3_onPC_win_v2.3.2.0.zip     # put this in nix/onpc-prefix.nix (src.sha256)
   nix store add-file --name grandMA3_onPC_win_v2.3.2.0.zip /path/to/it
   ```
2. **Private cache only.** Serving the built prefix from a *public* cache
   redistributes MA's software and violates their EULA. Build it on a licensed
   machine and serve it over a **private/authenticated** cache (e.g. Harmonia on
   your own host) to your own devices.

> Status: the build runs the MA installer under a headless `Xvfb` inside the Nix
> sandbox. This is the least-portable part (wine-prefix creation isn't fully
> hermetic) and should be built on a real licensed host, not CI.

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
