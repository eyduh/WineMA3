"""Network fix helpers for MA-Net under Wine."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .system import command_output, find_wineserver, run


@dataclass(frozen=True)
class FirewallState:
    key: str
    label: str
    rules_supported: bool


def set_wineserver_cap_net_raw() -> None:
    wineserver = find_wineserver()
    if not wineserver:
        raise RuntimeError("wineserver not found")
    target = wineserver_capability_target(Path(wineserver))
    run(["sudo", "setcap", "cap_net_raw=ep", str(target)], check=True)


def wineserver_capability_target(wineserver: Path) -> Path:
    target = wineserver.resolve()
    debian_64 = Path("/usr/lib/wine/wineserver64")
    debian_32 = Path("/usr/lib/wine/wineserver32")
    if target == Path("/usr/lib/wine/wineserver"):
        if debian_64.exists():
            return debian_64
        if debian_32.exists():
            return debian_32
    return target


def disable_ufw() -> None:
    run(["sudo", "ufw", "disable"], check=True)


def apply_ufw_rules(interface: str) -> None:
    rules = [
        ["sudo", "ufw", "allow", "in", "on", interface, "proto", "udp", "to", "236.4.0.0/16", "port", "30020", "comment", "grandMA3 MA-Net3 multicast"],
        ["sudo", "ufw", "allow", "in", "on", interface, "proto", "tcp", "to", "any", "port", "30022:30040", "comment", "grandMA3 MA-Net3 alternate TCP"],
        ["sudo", "ufw", "allow", "in", "on", interface, "proto", "tcp", "to", "any", "port", "8080", "comment", "grandMA3 web remote websocket"],
    ]
    for rule in rules:
        run(rule, check=True)


def apply_firewalld_rules() -> None:
    rules = [
        ["sudo", "firewall-cmd", "--permanent", "--add-port=30020/udp"],
        ["sudo", "firewall-cmd", "--permanent", "--add-port=30022-30040/tcp"],
        ["sudo", "firewall-cmd", "--permanent", "--add-port=8080/tcp"],
        ["sudo", "firewall-cmd", "--reload"],
    ]
    for rule in rules:
        run(rule, check=True)


def active_firewalls() -> list[FirewallState]:
    firewalls: list[FirewallState] = []
    if ufw_active():
        firewalls.append(FirewallState("ufw", "UFW", True))
    if firewalld_active():
        firewalls.append(FirewallState("firewalld", "firewalld", True))
    if nftables_active():
        firewalls.append(FirewallState("nftables", "nftables.service", False))
    if netfilter_persistent_active():
        firewalls.append(FirewallState("netfilter-persistent", "netfilter-persistent", False))
    return firewalls


def disable_firewalls(firewalls: list[FirewallState]) -> None:
    for firewall in firewalls:
        if firewall.key == "ufw":
            disable_ufw()
        elif firewall.key == "firewalld":
            run(["sudo", "systemctl", "disable", "--now", "firewalld"], check=True)
        elif firewall.key == "nftables":
            run(["sudo", "systemctl", "disable", "--now", "nftables"], check=True)
        elif firewall.key == "netfilter-persistent":
            run(["sudo", "systemctl", "disable", "--now", "netfilter-persistent"], check=True)


def apply_firewall_rules(firewalls: list[FirewallState], interface: str) -> list[str]:
    unsupported: list[str] = []
    for firewall in firewalls:
        if firewall.key == "ufw":
            apply_ufw_rules(interface)
        elif firewall.key == "firewalld":
            apply_firewalld_rules()
        else:
            unsupported.append(firewall.label)
    return unsupported


def ufw_active() -> bool:
    status = command_output(["ufw", "status"]).lower()
    if "status: active" in status:
        return True
    systemd = command_output(["systemctl", "is-active", "ufw"]).strip().lower()
    return systemd == "active"


def firewalld_active() -> bool:
    state = command_output(["firewall-cmd", "--state"]).strip().lower()
    if state == "running":
        return True
    systemd = command_output(["systemctl", "is-active", "firewalld"]).strip().lower()
    return systemd == "active"


def nftables_active() -> bool:
    systemd = command_output(["systemctl", "is-active", "nftables"]).strip().lower()
    return systemd == "active"


def netfilter_persistent_active() -> bool:
    systemd = command_output(["systemctl", "is-active", "netfilter-persistent"]).strip().lower()
    return systemd == "active"


def likely_primary_interface() -> str | None:
    route = command_output(["ip", "route"])
    for line in route.splitlines():
        parts = line.split()
        if parts and parts[0] == "default" and "dev" in parts:
            return parts[parts.index("dev") + 1]
    return None
