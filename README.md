# WineMA3

> **WIP / Experimental** — This branch is an active rewrite. Some features are
> broken or unfinished. Use at your own risk.
>
> Co-authored with Claude Code, Ollama, and Kimi k2.6.

Nix-native runner for grandMA3 onPC (professional lighting console software from
MA Lighting) on Linux. Uses a layered Wine prefix with DXVK and a custom
wintrust stub, mounted via overlayfs at runtime.

Target: **NixOS** and any flake-enabled Nix install on `x86_64-linux`.

## How it works

A Wine prefix containing DXVK, the wintrust stub, and registry patches is built
in Nix and mounted at runtime. Overlayfs keeps your user data intact.
`fuse-overlayfs` is fallen back to on hardened kernels.

## Running ad-hoc

```bash
nix run github:eyduh/WineMA3
```

## Installing on your system

### nix profile

```bash
nix profile install github:eyduh/WineMA3
```

### NixOS / Home Manager

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
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        inherit pkgs;
        modules = [
          winema3.nixosModules.default
          {
            programs.winema3.enable = true;
          }
        ];
      };
    };
}
```

## Installing grandMA3 onPC

grandMA3 onPC is proprietary software and cannot be redistributed. You must
provide your own installer.

### Runtime installation (recommended)

Download the Windows installer from
[malighting.com](https://www.malighting.com/downloads/) and run:

```bash
gma3 install /path/to/grandMA3_onPC_win_vX.Y.Z.W.exe
```

ZIP archives are also supported:

```bash
gma3 install /path/to/grandMA3_onPC_win_vX.Y.Z.W.zip
```

The runner verifies the installer hash against a known-hashes registry and
installs into the Wine prefix. After installation, run `gma3` to launch.

### NixOS module — bake the installer in at build time

If you want grandMA3 available immediately on first run (useful for show
machines), prefetch the installer into the Nix store and point the module to it:

```bash
nix-prefetch-url file:///path/to/grandMA3_onPC_win_v2.3.2.0.exe
```

Then in your NixOS config:

```nix
{
  programs.winema3.enable = true;
  programs.winema3.installerPath = "/nix/store/...-grandMA3_onPC_win_v2.3.2.0.exe";
}
```

The hash is verified at build time against `packages/known-hashes.json`.

## Subcommands

```bash
gma3 --help
```

| Command | Description |
|---------|-------------|
| `gma3` | Launch grandMA3 onPC (default) |
| `gma3 install <path>` | Install grandMA3 from an EXE or ZIP |
| `gma3 wine <cmd>` | Run any Wine command in the prefix |
| `gma3 winetricks` | Run winetricks |
| `gma3 wineboot` | Run wineboot |
| `gma3 wineserver` | Run wineserver |
| `gma3 probe` | System diagnostics |

## NixOS Module

Enable the module for automatic firewall, wineserver capabilities, and power
management:

```nix
{
  programs.winema3.enable = true;
}
```

This configures:
- Firewall: UDP `30020`, TCP `30022-30040`, TCP `8080`
- `security.wrappers.wineserver` with `cap_net_raw=ep`
- Power management: disables suspend/hibernate and display blanking

## Troubleshooting

**Overlayfs mount fails**: the runner automatically falls back to
`fuse-overlayfs`. If both fail, check that your kernel supports user namespaces.

**Reset user data** (uninstall grandMA3 from the prefix):
```bash
rm -rf ~/.local/share/gma3 ~/.local/state/gma3
```

**Unknown installer hash**: the installer is not in `packages/known-hashes.json`.
Add the hash and rebuild, or verify the file is correct.

## License

See LICENSE. The grandMA3 onPC installer is proprietary software from MA
Lighting Technology GmbH and is not included.
