"""Rich installer CLI."""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

from rich.console import Console
from rich.panel import Panel
from rich.prompt import Confirm, IntPrompt, Prompt
from rich.table import Table

from . import __version__
from .installers import MaInstaller, discover
from .networking import active_firewalls, apply_firewall_rules, disable_firewalls, likely_primary_interface, set_wineserver_cap_net_raw
from .power import disable_power_saving
from .system import detect_distro, find_wineserver, probe, run
from .wine_setup import install_prefix, ma_version_installed, prefix_path


console = Console()


def main(repo_root: Path) -> int:
    args = parse_args()
    console.print(Panel.fit(f"[bold]WineMA3[/bold] {__version__}\nWine-only grandMA3 onPC installer", border_style="cyan"))

    distro = detect_distro()
    probe_data = probe()
    show_probe(probe_data)
    show_proxmox_hint(probe_data)

    if distro is None:
        console.print("[red]Unsupported distro.[/red] Use a mainstream glibc distro: Arch/CachyOS, Debian/Ubuntu, Fedora, or openSUSE.")
        return 2

    installers = discover(repo_root)
    selected = select_installer(installers, repo_root)
    if selected is None:
        return 2

    console.print(Panel(
        f"Selected installer: [bold]{selected.display_source}[/bold]\n"
        f"Source type: [bold]{selected.kind}[/bold]\n"
        f"Version: [bold]{selected.version}[/bold]\n"
        f"Wine prefix: [bold]{prefix_path(selected)}[/bold]",
        title="Install Plan",
        border_style="green",
    ))

    prefix = prefix_path(selected)
    if prefix.exists():
        console.print(Panel(
            f"The target Wine prefix already exists:\n[bold]{prefix}[/bold]\n\n"
            "Continuing will reuse the existing prefix. Wine bootstrap will be skipped.",
            title="Existing Prefix",
            border_style="yellow",
        ))
        if not confirm("Use this existing prefix anyway?", default=False):
            console.print("Cancelled.")
            return 1

    run_ma_installer = True
    if args.noinstall:
        if not ma_version_installed(selected):
            console.print(Panel(
                "The target prefix does not contain grandMA3 yet, so --noinstall cannot refresh it.\n\n"
                "Run without --noinstall once to install the MA EXE.",
                title="Missing grandMA3 Install",
                border_style="red",
            ))
            return 2
        run_ma_installer = False
        console.print(Panel(
            "--noinstall selected. The MA installer EXE will not be run; Wine bootstrap, DXVK, wintrust patch, and launchers will still be refreshed.",
            title="Debug Install Mode",
            border_style="yellow",
        ))
    if ma_version_installed(selected):
        console.print(Panel(
            f"grandMA3 {selected.version} already appears to be installed in the target prefix.\n\n"
            "You can skip the MA installer and just refresh DXVK, the wintrust patch, and launchers.",
            title="Existing grandMA3 Install",
            border_style="yellow",
        ))
        if not args.noinstall:
            run_ma_installer = confirm("Run the silent MA installer again?", default=False)

    if not confirm("Continue with package installation and Wine prefix setup?", default=False):
        console.print("Cancelled.")
        return 1

    install_packages(distro)
    maybe_apply_network_fixes()
    maybe_disable_power_saving()
    with console.status("[bold green]Installing grandMA3 into Wine prefix...[/bold green]"):
        install_prefix(selected, repo_root, run_installer=run_ma_installer)

    console.print(Panel(
        "Installation complete.\n\n"
        "Run [bold]gma3[/bold] from a real terminal to start onPC.\n"
        "Run [bold]gma3term[/bold] to open app_terminal.exe for SYSMON/SYSNOW/SHELL/CMDLINE.",
        title="Done",
        border_style="green",
    ))
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install grandMA3 onPC into a Wine prefix.",
    )
    parser.add_argument(
        "--noinstall",
        action="store_true",
        help="skip running the MA installer EXE and only refresh Wine/DXVK/wintrust/launchers",
    )
    return parser.parse_args(sys.argv[1:] if argv is None else argv)


def show_probe(data: dict[str, str]) -> None:
    table = Table(title="System Probe", show_lines=True)
    table.add_column("Item", style="cyan", no_wrap=True)
    table.add_column("Value")
    for key, value in data.items():
        table.add_row(key, value or "missing")
    console.print(table)


def show_proxmox_hint(data: dict[str, str]) -> None:
    recommendation = data.get("Proxmox recommendation", "")
    if not recommendation.startswith("Proxmox VM detected:"):
        return
    console.print(Panel(
        recommendation
        + "\n\n"
        + "For grandMA3 onPC under Wine in a Proxmox VM, set:\n"
        + "CPU type: host\n"
        + "GPU/display: VirGL",
        title="Proxmox VM Settings",
        border_style="yellow",
    ))


def select_installer(installers: list[MaInstaller], repo_root: Path) -> MaInstaller | None:
    if not installers:
        console.print(Panel(
            "No MA Windows installer EXE found.\n\n"
            f"Place grandMA3_onPC_win_*.exe in:\n[bold]{repo_root / 'ma3onpcinstaller'}[/bold]\n\n"
            "Then rerun: python3 install.py",
            title="Missing Installer",
            border_style="red",
        ))
        return None
    if len(installers) == 1:
        installer = installers[0]
        console.print(f"Using detected installer: [bold]{installer.display_source}[/bold]")
        return installer

    table = Table(title="Detected MA Installers")
    table.add_column("#", justify="right")
    table.add_column("Type")
    table.add_column("Source")
    table.add_column("EXE")
    table.add_column("Version")
    table.add_column("Size")
    table.add_column("Modified")
    for idx, installer in enumerate(installers, start=1):
        mtime = dt.datetime.fromtimestamp(installer.mtime).strftime("%Y-%m-%d %H:%M")
        table.add_row(
            str(idx),
            installer.kind,
            installer.source_path.name if installer.source_path else installer.path.name,
            installer.archive_member or installer.path.name,
            installer.version,
            f"{installer.size_mb:.1f} MiB",
            mtime,
        )
    console.print(table)
    choice = IntPrompt.ask("Which installer should be used?", choices=[str(i) for i in range(1, len(installers) + 1)])
    return installers[choice - 1]


def install_packages(distro) -> None:
    packages = list(distro.packages)
    console.print(Panel(
        f"Distro: [bold]{distro.name}[/bold]\n"
        f"Package manager: [bold]{distro.package_manager}[/bold]\n"
        f"Packages: {' '.join(packages)}",
        title="Package Install",
    ))
    if confirm("Install/verify required native packages now?", default=True):
        if distro.package_manager == "apt-get":
            ensure_apt_i386_architecture()
        run([*distro.install_command, *packages], check=True)


def ensure_apt_i386_architecture() -> None:
    result = run(["dpkg", "--print-foreign-architectures"], capture=True)
    foreign_arches = set((result.stdout or "").split())
    if "i386" in foreign_arches:
        return
    console.print("[yellow]Enabling i386 multiarch for wine32 support.[/yellow]")
    run(["sudo", "dpkg", "--add-architecture", "i386"], check=True)
    run(["sudo", "apt-get", "update"], check=True)


def maybe_apply_network_fixes() -> None:
    if find_wineserver() and confirm("Set cap_net_raw on wineserver for MA-Net networking?", default=True):
        set_wineserver_cap_net_raw()
        console.print("[green]wineserver cap_net_raw set.[/green]")

    firewalls = active_firewalls()
    if not firewalls:
        return

    firewall_list = ", ".join(firewall.label for firewall in firewalls)
    unsupported_rules = [firewall.label for firewall in firewalls if not firewall.rules_supported]
    console.print(Panel(
        f"Active firewall services detected: {firewall_list}\n\n"
        "MA-Net uses multicast UDP 30020 and additional TCP ports.\n"
        "For a trusted LAN-only MA VM, disabling host firewalls removes this variable entirely.",
        title="Networking",
        border_style="yellow",
    ))
    if unsupported_rules:
        console.print(
            "[yellow]Rule mode is not available for: "
            + ", ".join(unsupported_rules)
            + ". Choose disable for a fully open trusted MA VM.[/yellow]"
        )
    action = prompt_choice(
        "Firewall action",
        choices=["disable", "rules", "skip"],
        default="disable",
    )
    if action == "disable":
        disable_firewalls(firewalls)
        console.print("[green]Active firewall services disabled.[/green]")
    elif action == "rules":
        interface = likely_primary_interface() or Prompt.ask("Interface for MA-Net rules", default="ens18")
        unsupported = apply_firewall_rules(firewalls, interface)
        if unsupported:
            console.print(f"[yellow]Skipped unsupported firewall rule backends: {', '.join(unsupported)}.[/yellow]")
        console.print(f"[green]MA-Net firewall rules applied on {interface} where supported.[/green]")
    else:
        console.print("[yellow]Skipped firewall changes.[/yellow]")


def maybe_disable_power_saving() -> None:
    console.print(Panel(
        "grandMA3 systems should not suspend, lock, blank the display, or turn off displays while a show is running.\n\n"
        "This applies systemd sleep blocks, X11 DPMS/screensaver settings, and a desktop autostart helper for the current user.",
        title="Power Saving",
        border_style="yellow",
    ))
    if not confirm("Disable OS suspend, screensaver, screen lock, and display power saving?", default=True):
        console.print("[yellow]Skipped power saving changes.[/yellow]")
        return
    disable_power_saving()
    console.print("[green]OS sleep and desktop idle power saving disabled.[/green]")


def confirm(message: str, *, default: bool) -> bool:
    try:
        return Confirm.ask(message, default=default)
    except EOFError:
        console.print(f"[yellow]No interactive input available; using default: {default}[/yellow]")
        return default


def prompt_choice(message: str, *, choices: list[str], default: str) -> str:
    try:
        return Prompt.ask(message, choices=choices, default=default)
    except EOFError:
        console.print(f"[yellow]No interactive input available; using default: {default}[/yellow]")
        return default
