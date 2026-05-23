# WineMA3

WineMA3 is a Nix-native runner for grandMA3 onPC (professional lighting console
software from MA Lighting) on Linux. It builds a layered Wine prefix with DXVK
and a custom wintrust stub, then mounts it via overlayfs at runtime for a clean,
immutable-base + mutable-upper experience.

Target systems: **NixOS** (primary) and any flake-enabled Nix install on
`x86_64-linux`.

## Quick Start (1-2-3)

grandMA3 onPC is proprietary software and cannot be redistributed. You must
provide your own installer.

1. **Download** the grandMA3 onPC Windows installer from
   [malighting.com](https://www.malighting.com/downloads/).

2. **Prefetch** it into the Nix store:
   ```bash
   nix-prefetch-url file:///path/to/grandMA3_onPC_win_vX.Y.Z.W.exe
   ```
   This prints a `sha256` hash and adds the file to `/nix/store/`.

   ZIP archives are also supported:
   ```bash
   nix-prefetch-url file:///path/to/grandMA3_onPC_win_vX.Y.Z.W.zip
   ```

3. **Provide** the hash in `packages/sources.nix` (set `sha256` and optionally
   `name`), then build and run:
   ```bash
   nix run .#gma3
   ```

## Installation Methods

### Ephemeral (nix run)

Run without installing:
```bash
nix run github:eyduh/WineMA3
```

### User profile (nix profile)

Add to your user profile:
```bash
nix profile install github:eyduh/WineMA3
```

### NixOS / Home Manager (declarative)

Add the overlay and package to your system configuration:
```nix
{
  inputs.winema3.url = "github:eyduh/WineMA3";

  outputs = { self, nixpkgs, winema3, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ winema3.overlays.default ];
      };
    in
    {
      # NixOS configuration
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        inherit pkgs;
        modules = [
          winema3.nixosModules.default
          {
            programs.winema3.enable = true;
            programs.winema3.package = pkgs.winema3;
          }
        ];
      };
    };
}
```

### NixOS Module

Enable the module for automatic firewall rules, wineserver capabilities, and
power management:
```nix
{
  programs.winema3.enable = true;
}
```

This configures:
- Firewall: UDP `30020`, TCP `30022-30040`, TCP `8080`
- `security.wrappers.wineserver` with `cap_net_raw=ep`
- Power management: disables suspend/hibernate and display blanking

## Build-Time vs Runtime Installation

By default, the lowerdir (immutable Wine prefix) does **not** include grandMA3.
The runner mounts this base prefix and checks for `app_system.exe` in the
upperdir (your `~/.local/share/gma3/`). If it is missing, it prints instructions
for runtime installation via `gma3 wine installer.exe /S`.

Alternatively, you can **bake the installer into the lowerdir** at build time
so grandMA3 is available immediately on first run:

1. Set `sha256` in `packages/sources.nix` as described in Quick Start.
2. Build the prefixed package:
   ```bash
   nix build .#winema3-prefix-with-gma3
   ```
3. Override the runner to use it as the lowerdir:
   ```nix
   programs.winema3.package = pkgs.winema3.override {
     prefixBase = pkgs.winema3-prefix-with-gma3;
   };
   ```

This is useful for dedicated show machines where you want zero runtime setup.

## Subcommands

The `winema3-runner` binary (exposed as `gma3`) supports:

- `gma3` (default) — launch grandMA3 onPC
- `gma3 wine <cmd>` — run any Wine command in the prefix
- `gma3 winetricks` — run winetricks
- `gma3 wineboot` — run wineboot
- `gma3 wineserver` — run wineserver
- `gma3 probe` — system diagnostics

## Architecture

- **Nix (~57%)** — packaging, Wine prefix derivation, overlayfs setup, NixOS
  module
- **Rust (~41%)** — runtime runner (`crates/runner/`): overlayfs mount,
  XDG paths, Wine proxying, CLI
- **Python (~2%)** — NixOS VM test script (`tests/gma3.py`)

## Runtime Paths

- Upper (user data): `~/.local/share/gma3/`
- Workdir: `~/.local/state/gma3/`
- Runtime mount: `/run/user/<uid>/gma3-prefix-<pid>/`

## Multi-Version Support

The runner uses Cargo feature flags for different grandMA3 versions. The overlay
exposes versioned packages such as `gma3-v2320`, `gma3-v2330`, etc.

## Troubleshooting

**Overlayfs mount fails**: the runner automatically falls back to
`fuse-overlayfs`. If both fail, check that your kernel supports user namespaces
and overlayfs.

**Reset the upperdir** (user data layer):
```bash
rm -rf ~/.local/share/gma3 ~/.local/state/gma3
```

**Switch grandMA3 versions**: change the version in your overlay and rebuild.
The lowerdir (immutable base prefix) will change, but your upperdir (user data)
will remain.

## Technical Notes

- Uses stock `wineWow64Packages.full` from nixpkgs (no custom Wine fork)
- DXVK is provided at runtime via `WINEPATH`, not baked into the prefix
- `wintrust.dll` stub is cross-compiled with MinGW at build time
- Registry patches (`wintrust=n,b`, `dxgi=n`, `d3d11=n`) are applied at build
  time

## License

See LICENSE. The grandMA3 onPC installer is proprietary software from MA
Lighting Technology GmbH and is not included.
