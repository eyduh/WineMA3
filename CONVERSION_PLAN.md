# WineMA3 Nix Conversion Plan

> Analysis of converting WineMA3 from a Python-based installer to a Nix/Rust/Python
> architecture modeled on [affinity-nix](https://github.com/mrshmllow/affinity-nix/).

## Executive Summary

This document captures the findings from a three-agent parallel analysis of
affinity-nix and maps them to a conversion strategy for WineMA3. The target
architecture is:

- **Nix** (~57%): Flake, overlays, package derivations, Wine prefix build,
  desktop icons, NixOS modules
- **Rust** (~41%): Runtime runner (overlayfs mounting, Wine proxying, CLI,
  migrations, registry warmup)
- **Python** (~2%): NixOS VM tests, optional diagnostic probe script

Target OS: **NixOS** (primary), with support for any flake-enabled Nix install
on `x86_64-linux`.

---

## 1. Current WineMA3 Architecture

### Entry Points
- `install.py` -- Ensures Python Rich dependency, then calls `wine_ma3.cli.main()`
- `probe.py` -- Prints system probe data
- `uninstall.py` -- Removes launchers and prefixes

### `wine_ma3` Package
- `cli.py` -- Rich CLI orchestrator (installer selection, prompts, installation flow)
- `system.py` -- Distro detection, system probing (CPU/GPU/VM detection), command execution
- `installers.py` -- Discovers grandMA3 installers (EXE/ZIP in `ma3onpcinstaller/`), version inference
- `wine_setup.py` -- Wine prefix creation, DXVK setup, wintrust.dll stub build/install, launcher generation (`gma3`, `gma3term`, fish helpers, desktop files)
- `networking.py` -- Firewall detection (UFW, firewalld), wineserver capabilities, MA-Net port rules
- `power.py` -- Systemd sleep masking, Xorg DPMS config, desktop idle settings for GNOME/XFCE/KDE

---

## 2. affinity-nix Architecture Analysis

### Repository Layout
```
.flake.nix / flake.lock / overlay.nix / default.nix
.packages/
  wine/          -- Wine derivation, symlink, wrapWithPrefix
  affinity/      -- V2 product packages (Photo, Designer, Publisher)
  affinity-v3/   -- V3 unified package
  apl/           -- Plugin loader (bootstrap DLL built with mingw-w64)
  basePrefix.nix -- Layered Wine prefix build
  prefixWithAffinity.nix -- Affinity installer integration
  sources.nix    -- fetchurl for proprietary installer EXEs
  registry-patches.nix -- Wine registry tweaks
  runner/        -- Rust runner Nix package (built with crane)
.nix/
  hooks.nix      -- Pre-commit hooks
  fmt.nix        -- treefmt configuration
  shells.nix     -- devShells
.crates/runner/  -- Rust runtime launcher
.tests/          -- NixOS VM tests with Python scripts
```

### Programming Languages
- **Nix** (~57.2%): Derivations, Wine prefix, runtime mounting, overlays
- **Rust** (~40.9%): Launcher binary (`crates/runner/`), CLI, overlayfs, Wine proxying
- **Python** (~1.9%): NixOS VM tests only (`tests/v2.py`, `tests/v3.py`)

### Flake Inputs
| Input | Purpose |
|-------|---------|
| `nixpkgs-wine` | Known-good nixpkgs rev for wineWow64Packages.full |
| `nixpkgs` | General packages (nixos-unstable) |
| `elemental-wine-source` | ElementalWarrior Wine fork (GitLab) |
| `flake-parts` | Module system for flake outputs |
| `crane` | Rust build infrastructure for Nix |
| `fenix` | Rust toolchain provider |
| `plugin-loader-src` | .NET plugin loader |
| `on-linux` | Auxiliary Linux settings |
| `corefonts` | Core fonts for winetricks caching |

### Outputs Structure
Uses `flake-parts.lib.mkFlake` with modules:
- `packages/` -- Package definitions (Wine, products)
- `overlay.nix` -- Exposes packages via overlay
- `tests/default.nix` -- NixOS VM tests
- `nix/shells.nix` -- devShells

### Rust Runner (`crates/runner/`)

#### Dependencies
```toml
anyhow = "1.0.102"
clap = { version = "4.6.0", features = ["derive"] }
duct = "1.1.1"
mutually_exclusive_features = "0.1.0"
nix = { version = "0.31.2", features = ["sched", "mount"] }
tracing = "0.1.44"
tracing-subscriber = "0.3.23"
walkdir = "2.5.0"
xdgdir = "0.8.0"
```

#### CLI Structure
```rust
#[derive(Parser, Debug)]
struct Arguments {
    #[arg(long)]
    verbose: bool,
    #[command(subcommand)]
    subcommand: Option<Program>,
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    affinity_arguments: Vec<String>,
}

#[derive(Subcommand, Debug)]
enum Program {
    Wine { arguments: Vec<String> },
    Winetricks { arguments: Vec<String> },
    Wineboot { arguments: Vec<String> },
    Wineserver { arguments: Vec<String> },
}
```

#### Runtime Directory Model (`Paths` struct)
- `upper` -> `~/.local/share/affinity-v3/` (via `xdgdir::BaseDir` `.data`)
- `work` -> `~/.local/state/affinity-v3/` (via `.state`)
- `wine_prefix` -> `$XDG_RUNTIME_DIR/affinity-nix-prefix-<pid>` (via `.runtime`)

#### Namespace Isolation & OverlayFS Mounting
1. `unshare(CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID)`
2. Write `"deny\n"` to `/proc/self/setgroups`
3. Map UID/GID: `"0 <uid> 1\n"` to `/proc/self/uid_map` and `gid_map`
4. `fork()` a child; child calls `prctl(PR_SET_PDEATHSIG, SIGKILL)`
5. Child performs privileged `mount("overlay", wine_prefix, "overlay", MsFlags::empty(), options)`
6. If mount fails with status 111 -> fallback to `fuse-overlayfs`
7. Cleanup: `umount()` or `fusermount3 -u -z`

Mount options: `lowerdir=<LOWER_DIR>,upperdir=<upper>,workdir=<work>`

`LOWER_DIR` is the immutable Nix-built prefix, baked in at compile time via
`env!("LOWER_DIR")`.

#### Prefix Warmup (before mounting)
- `warmup_prefix_directories(destination)` -- Walks `LOWER_DIR` recursively and
  pre-creates every directory in the `upper` layer.
- `warmup_prefix_registry(destination, &user)` -- Copies `system.reg`, `user.reg`,
  `userdef.reg`, `.update-timestamp` from `LOWER_DIR` into `upper`, replacing
  `"nixbld"` with current `$USER` and setting `S_IWUSR`.

#### wineboot Update
After mounting, runs `wineboot --update` to let Wine initialize any missing
runtime files before the real application starts.

#### Migration / Revision Tracking
- `migrate::migrate()` checks revision via `check::read_revision()`
- If stored revision < 9: GUI dialog (`zenity --question`) asks for backup
  permission, then backs up old data to `$HOME/affinity-nix-backup-<pid>.tar.zst`
  and wipes non-user data from `drive_c` (preserving `users/`)
- `perform_migrations()` in `check.rs` applies silent registry patch
  (`wine regedit /S one.reg`) if revision < 10, then writes `LATEST_REVISION`

#### Command Proxying
All proxied through `ProgramToExecute` enum:
- **Affinity (default):** Runs the Affinity executable from the mounted prefix
- **Wine:** `cmd(WINE, arguments)`
- **Winetricks:** `cmd(WINETRICKS, arguments)`
- **Wineboot:** `cmd(WINE, "wineboot".into_iter().chain(arguments))`
- **Wineserver:** `cmd(WINESERVER, arguments)`

After app exits, always runs `wineserver -w` to wait for all Wine processes.

#### Environment Variables
```rust
fn make_env(expression: duct::Expression, wine_prefix: &Path, verbose: bool) -> duct::Expression {
    let expression = expression.env("WINEPREFIX", wine_prefix.display().to_string());
    if verbose { return expression; }
    expression.env("WINEDEBUG", "-all,fixme-all".to_string())
}
```

Only two variables explicitly managed: `WINEPREFIX` and `WINEDEBUG`.
Everything else inherited from parent shell.

---

### Wine Prefix Build (Layered Derivations)

#### Layer 1 (`base-prefix-1`)
- `wineboot --update`
- Install `wine-mono` MSI
- Registry tweak: disable `winemenubuilder.exe` and file associations
- `winetricks renderer=vulkan`
- Install `.winmd` metadata files

#### Layer 2 (`base-prefix-2`)
- Copy Layer 1, make writable
- `winecfg -v win7`
- `xvfb-run wine MicrosoftEdgeWebView2RuntimeInstallerX64.exe /silent /install`
- `winecfg -v win11`
- Registry: disable Edge update services
- `taskkill /f /im MicrosoftEdgeUpdate.exe`

#### Layer 3 (`base-prefix-3`)
- Copy Layer 2, make writable
- Pre-seed winetricks cache from `linkFarm` of `fetchurl` downloads
- `xvfb-run winetricks -q -f <verbs>` (tahoma, vcrun2022, dotnet20, dotnet48, corefonts, win11)

#### Layer 4 (`base-prefix-4` / `prefixWithAffinity.nix`)
- Copy Layer 3, make writable
- Copy VKD3D-Proton DLLs to `system32`
- Registry patch for `d3d12`/`d3d12core` = native
- `lndir` Affinity binaries into `drive_c/Program Files/`
- Copy plugin loader files
- Remove `nixbld` user directory

Key technique: Each layer copies previous (`cp -a ${layer_n}/. $out`), makes
writable (`chmod -R +w`), adds new state, runs `wineserver -w`.

### Wine Derivation (`packages/wine/`)

#### `packages.nix`
```nix
wineUnstable =
  (inputs.nixpkgs-wine.legacyPackages.${stdenv.hostPlatform.system}.wineWow64Packages.full.override {
    wineRelease = "unstable";
  }).overrideAttrs {
    src = inputs.elemental-wine-source;
    version = "9.13-part3";
  };
```

#### `symlink.nix`
Copies Wine binaries (dereferencing symlinks) and symlinks `lib`, `share`, `include`.

#### `wrapWithPrefix.nix`
Generates wrapped binaries injecting:
- `LD_LIBRARY_PATH="${wineUnwrapped}/lib:$LD_LIBRARY_PATH"`
- `WINESERVER`, `WINELOADER`, `WINEDLLPATH`, `WINE`
- `PATH` with standard tools

### Overlay (`overlay.nix`)

```nix
flake.overlays.default = _final: prev:
  withSystem prev.stdenv.hostPlatform.system (_: {
    affinity-v3 = prev.callPackage ./packages/affinity-v3/package.nix { ... };
    affinity-photo = prev.callPackage ./packages/affinity/package.nix { name = "Photo"; ... };
    ...
  });
```

Consumers add `affinity-nix.overlays.default` to their nixpkgs overlays and
can reference `pkgs.affinity-v3` declaratively.

---

## 3. Mapping WineMA3 to Nix/Rust/Python

### Module-by-Module Mapping

| WineMA3 Module | New Location | Notes |
|---------------|-------------|-------|
| `install.py` | **Eliminated** | Nix handles all dependency provisioning declaratively |
| `cli.py` | `crates/runner/src/main.rs` | `clap` CLI: `--verbose`, subcommands (`wine`, `winetricks`, `wineboot`, `wineserver`, default `gma3`) |
| `system.py` | **Eliminated** | No distro detection/package install needed in Nix |
| `installers.py` | `packages/sources.nix` + Rust runner | Nix `requireFile` for installer; Rust scans local dir if user provides path |
| `wine_setup.py` | Split: Nix + Rust | Prefix build in `basePrefix.nix`, launcher generation in Rust, `.desktop` in Nix |
| `networking.py` | `nix/module.nix` | Declarative NixOS firewall + `security.wrappers.wineserver` with `cap_net_raw` |
| `power.py` | `nix/module.nix` | Declarative `systemd.sleep`, `services.xserver` settings |

### Feature-by-Feature Mapping

| WineMA3 Feature | affinity-nix Equivalent | Implementation |
|-----------------|------------------------|------------------|
| Launcher scripts (`gma3`, `gma3term`) | Runner binary itself | Rust binary with feature flags |
| `WINEPREFIX` env var | `make_env()` in Rust | Points to runtime overlay mount, not static home dir |
| `wineboot -u` on launch | `wineboot_update()` | Runs before every application start |
| Registry patches | `perform_migrations()` in `check.rs` | Revision-tracked, idempotent |
| winetricks/wine/wineserver access | Subcommands in Rust runner | Direct proxy with trailing args |
| Distro package installation | Not present | All deps declared in Nix closure |
| System probing (GPU, Vulkan, etc.) | Not present | Could become Rust `probe` subcommand |
| DXVK installation | `winetricks dxvk` in prefix build | Build-time, not runtime |
| wintrust.dll stub | `pkgsCross.mingwW64` build | Build-time in Nix derivation |
| Interactive Rich console UI | Not present | Rust runner is non-interactive; could keep Python TUI wrapper |
| Power management | Not present | NixOS module or Rust `power` subcommand |
| Networking fixes | Not present | NixOS `security.wrappers` + firewall config |
| Desktop / launcher integration | `desktopItems.nix` + `icons.nix` | Nix `makeDesktopItem`, `makeWrapper` |
| MA installer EXE execution | Not present | Runtime `wine` subcommand or `requireFile` in build |
| Full env var setup | Minimal in runner | WineMA3 runner needs `WINEARCH`, `MESA_*`, `DXVK_*`, `WINEDLLOVERRIDES` |

---

## 4. Key Technical Decisions

### 4.1 Wine Fork: Stock nixpkgs Wine

Unlike affinity-nix (which uses ElementalWarrior's Wine fork), grandMA3 onPC
runs fine on stock `wineWow64Packages.full` from nixpkgs. No custom Wine source
is needed.

### 4.2 Installer Handling (Critical)

MA Lighting does not provide public CDN links for grandMA3 onPC. Options:

**Option A: `requireFile` (Recommended for Nix purity)**
The user downloads the installer manually, runs `nix-prefetch-url
file:///path/to/installer` to get the hash, and the hash is pinned in
`sources.nix`.

**Option B: Runtime Installation (Preserves current UX)**
Keep the Nix package pure up to the prefix layer (Wine, DXVK, winetricks,
wintrust stub), but do NOT include grandMA3. At runtime, the overlayfs launcher
checks if `app_system.exe` exists in the upperdir; if not, it prompts the user
to run an installer subcommand:
```bash
gma3-runner wine /path/to/grandMA3_onPC_win.exe /S
```
This mirrors affinity-nix's `wine`, `winetricks`, `wineboot` subcommands.

**Option C: Fixed-Output Derivation (FOD)**
```nix
installer = pkgs.fetchurl {
  url = "file:///home/user/Downloads/grandMA3_onPC_win_v2.3.2.0.exe";
  sha256 = "...";
};
```
Works for one-off local packages but encodes absolute user paths.

### 4.3 wintrust.dll Stub

Build at Nix build time using `pkgsCross.mingwW64.stdenv.cc`:

```nix
wintrustStub = pkgs.runCommand "wintrust-stub" {
  nativeBuildInputs = [ pkgs.pkgsCross.mingwW64.stdenv.cc ];
} ''
  mkdir -p $out
  cat > wintrust_stub.c <<'EOF'
  #include <windef.h>
  #include <wintrust.h>
  LONG WINAPI WinVerifyTrust(...) { SetLastError(ERROR_SUCCESS); return ERROR_SUCCESS; }
  EOF
  x86_64-w64-mingw32-gcc -shared -o $out/wintrust.dll wintrust_stub.c -Wl,--kill-at
'';
```

Install into prefix: `cp ${wintrustStub}/wintrust.dll $out/drive_c/windows/system32/`
Registry override: `wine reg add 'HKCU\Software\Wine\DllOverrides' /v wintrust /t REG_SZ /d native,builtin /f`

### 4.4 DXVK

Apply via `winetricks dxvk` in `basePrefix.nix` layer, matching WineMA3's
current approach. Environment: `WINEDLLOVERRIDES="wintrust=n,b;dxgi,d3d11=n"`.

### 4.5 OverlayFS Runtime

Directly port affinity-nix's Rust pattern:
1. `unshare` user namespace + mount namespace + PID namespace
2. Map UID/GID to root
3. `fork()` child with `PR_SET_PDEATHSIG`
4. Kernel `mount("overlay", ...)` with `lowerdir/upperdir/workdir`
5. Fallback to `fuse-overlayfs` if mount fails
6. Cleanup: `umount()` or `fusermount3 -u -z`

XDG Base Directory paths:
- Data (upper): `$XDG_DATA_HOME/gma3/` (typically `~/.local/share/gma3/`)
- State (work): `$XDG_STATE_HOME/gma3/` (typically `~/.local/state/gma3/`)
- Runtime (mount): `$XDG_RUNTIME_DIR/gma3-prefix-<pid>/`

### 4.6 Environment Variables

The Rust runner's `make_env()` must set WineMA3-specific variables, unlike
affinity-nix which only sets `WINEPREFIX` and `WINEDEBUG`:

```rust
fn make_env(expression: duct::Expression, wine_prefix: &Path, verbose: bool) -> duct::Expression {
    let expression = expression
        .env("WINEPREFIX", wine_prefix.display().to_string())
        .env("WINEARCH", "win64")
        .env("LANG", "en_US.UTF-8")
        .env("LC_ALL", "en_US.UTF-8")
        .env("MESA_GL_VERSION_OVERRIDE", "4.2")
        .env("MESA_GLSL_VERSION_OVERRIDE", "420")
        .env("WINEDLLOVERRIDES", "wintrust=n,b;dxgi,d3d11=n")
        .env("DXVK_LOG_LEVEL", "info")
        .env("DXVK_LOG_PATH", "...");
    if verbose { expression } else { expression.env("WINEDEBUG", "-all,fixme-all") }
}
```

### 4.7 NixOS Module

Provide `programs.winema3.enable` option that configures:

**Firewall:**
```nix
networking.firewall = {
  allowedUDPPorts = [ 30020 ];
  allowedTCPPorts = [ 8080 ] ++ builtins.genList (x: 30022 + x) 19; # 30022-30040
};
```

**wineserver capabilities:**
```nix
security.wrappers.wineserver = {
  setuid = false;
  owner = "root";
  group = "root";
  capabilities = "cap_net_raw=ep";
  source = "${wineUnwrapped}/bin/wineserver";
};
```

**Power management:**
```nix
systemd.sleep.extraConfig = ''
  AllowSuspend=no
  AllowHibernation=no
  AllowHybridSleep=no
  AllowSuspendThenHibernate=no
'';
services.xserver.serverFlagsSection = ''
  Option "BlankTime" "0"
  Option "StandbyTime" "0"
  Option "SuspendTime" "0"
  Option "OffTime" "0"
'';
```

---

## 5. Proposed New File Layout

```
flake.nix                          # Flake inputs/outputs, flake-parts modules
overlay.nix                        # Exposes packages for NixOS/Home Manager
default.nix                        # Compatibility for non-flake consumers
Cargo.toml / Cargo.lock            # Rust workspace root

.crates/
  runner/
    Cargo.toml
    src/
      main.rs                      # CLI (clap), overlayfs mount, Wine proxying
      check.rs                     # Revision tracking, registry migrations
      migrate.rs                   # Prefix migration/upgrade logic

packages/
  wine/
    default.nix                    # Exports wine-packages
    packages.nix                   # Wine derivation (stock nixpkgs)
    symlink.nix                    # Symlink wine binaries/lib/share
    wrapWithPrefix.nix             # Wrapper injecting WINEPATH/env vars
  basePrefix.nix                   # Layered Wine prefix build
  prefixWithGma3.nix               # GrandMA3 installer integration
  sources.nix                      # requireFile for proprietary installer
  registry-patches.nix             # Wine registry tweaks
  wintrust.nix                     # MinGW cross-compile wintrust.dll stub
  desktopItems.nix                 # .desktop entries for gma3, gma3term
  icons.nix                        # Icon derivation from assets/

nix/
  hooks.nix                        # Pre-commit hooks
  fmt.nix                          # treefmt config
  shells.nix                       # devShells with Rust/Wine tooling
  module.nix                       # NixOS module: firewall, power mgmt, capabilities

tests/
  default.nix                      # NixOS VM test definition
  gma3.py                          # VM test script

# Retained from current repo:
assets/winema3-grandma3.svg        # Icon asset
README.md                          # Updated for Nix usage
```

---

## 6. Implementation Phases

| Phase | Files | Description |
|-------|-------|-------------|
| **1. Nix scaffolding** | `flake.nix`, `overlay.nix`, `nix/*.nix`, `packages/wine/*.nix` | Flake with flake-parts, Wine derivation, devShell |
| **2. Wine prefix derivation** | `packages/basePrefix.nix`, `packages/wintrust.nix`, `packages/registry-patches.nix` | Layered prefix: wineboot, dxvk, wintrust stub, registry tweaks |
| **3. Rust runner** | `crates/runner/Cargo.toml`, `src/main.rs`, `src/check.rs`, `src/migrate.rs` | Overlayfs mounting, CLI, Wine proxying, XDG paths, env vars |
| **4. GrandMA3 packaging** | `packages/prefixWithGma3.nix`, `packages/sources.nix`, `packages/desktopItems.nix`, `packages/icons.nix` | Installer requireFile, .desktop entries, icon derivation |
| **5. NixOS module** | `nix/module.nix` | Firewall, wineserver capabilities, power management |
| **6. Tests & docs** | `tests/default.nix`, `tests/gma3.py`, `README.md` | NixOS VM test, updated documentation |
| **7. Cleanup** | Delete old Python files | Remove `install.py`, `probe.py`, `uninstall.py`, `wine_ma3/` |

---

## 7. Summary Comparison Table

| Concern | affinity-nix | WineMA3 (Current) | WineMA3 (Target) |
|---|---|---|---|
| **Wine fork** | ElementalWarrior, pinned in flake | Host distro package | Stock nixpkgs `wineWow64Packages.full` |
| **Prefix creation** | Immutable Nix derivations (layer_1..4) | Runtime in `~/.wine-gma...` | Immutable Nix derivations + overlayfs |
| **winetricks** | Build-time, cached, xvfb-run | Runtime, host internet | Build-time, cached, xvfb-run |
| **DXVK/VKD3D** | VKD3D-Proton + registry patch | DXVK via winetricks | DXVK via winetricks in build |
| **Overlayfs** | Kernel overlay or fuse-overlayfs | Not used | Kernel overlay or fuse-overlayfs |
| **Persistence** | Upperdir (`$XDG_DATA_HOME`) + lowerdir (Nix store) | Single persistent prefix | Upperdir (`$XDG_DATA_HOME`) + lowerdir (Nix store) |
| **Networking** | Would need NixOS wrappers + firewall config | Runtime `setcap` + `ufw`/`firewalld` | NixOS `security.wrappers` + `networking.firewall` |
| **Power mgmt** | Would need NixOS modules / Home Manager | Runtime `sudo` to write `/etc/` | NixOS `systemd.sleep` + `services.xserver` |
| **wintrust stub** | `runCommand` with `mingw-w64` | Runtime `gcc` + copy | Build-time in Nix derivation |
| **Proprietary installer** | Fetched from CDN (`fetchurl`) | Discovered from local `ma3onpcinstaller/` | `requireFile` or runtime `wine` subcommand |
| **CLI** | Non-interactive Rust runner | Interactive Rich TUI | Rust runner + optional Python TUI wrapper |
| **Desktop integration** | `makeDesktopItem` + `makeWrapper` | Generated bash scripts | `makeDesktopItem` + `makeWrapper` |

---

*Generated from parallel analysis of affinity-nix and WineMA3 on 2026-05-23.*
