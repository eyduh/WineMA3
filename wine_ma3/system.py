"""System probing and command helpers."""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Distro:
    distro_id: str
    distro_like: str
    name: str
    package_manager: str
    install_command: list[str]
    packages: list[str]
    rich_package: str


def run(
    command: list[str],
    *,
    check: bool = False,
    capture: bool = False,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    timeout: int | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        cwd=cwd,
        env=env,
        text=True,
        timeout=timeout,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def command_output(command: list[str]) -> str:
    try:
        return run(command, capture=True, timeout=10).stdout or ""
    except (FileNotFoundError, PermissionError, OSError, subprocess.SubprocessError):
        return ""


def find_wineserver() -> str | None:
    path = shutil.which("wineserver")
    if path:
        return path
    candidates = [
        Path("/usr/lib/wine/wineserver64"),
        Path("/usr/lib/wine/wineserver"),
        Path("/usr/lib/x86_64-linux-gnu/wine/wineserver"),
        Path("/usr/lib/i386-linux-gnu/wine/wineserver"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return str(candidate)
    return None


def desktop_command_output(command: list[str]) -> str:
    env = os.environ.copy()
    runtime_dir = env.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    env.setdefault("DISPLAY", ":0")
    env.setdefault("XDG_RUNTIME_DIR", runtime_dir)
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime_dir}/bus")
    try:
        return run(command, capture=True, env=env, timeout=10).stdout or ""
    except (FileNotFoundError, PermissionError, OSError, subprocess.SubprocessError):
        return ""


def read_os_release() -> dict[str, str]:
    path = Path("/etc/os-release")
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value.strip().strip('"')
    return data


def detect_distro() -> Distro | None:
    os_release = read_os_release()
    distro_id = os_release.get("ID", "").lower()
    distro_like = os_release.get("ID_LIKE", "").lower()
    name = os_release.get("PRETTY_NAME", distro_id or platform.platform())
    tokens = f"{distro_id} {distro_like}"

    if any(x in tokens for x in ("arch", "cachyos", "manjaro")):
        return Distro(
            distro_id,
            distro_like,
            name,
            "pacman",
            ["sudo", "pacman", "-S", "--needed", "--noconfirm"],
            ["wine", "wine-mono", "wine-gecko", "winetricks", "vulkan-swrast", "vulkan-tools", "mingw-w64-gcc", "mesa-utils", "xorg-xset"],
            "python-rich",
        )
    if any(x in tokens for x in ("debian", "ubuntu")):
        apt_packages = ["wine", "wine64", "wine32:i386", "mesa-utils", "vulkan-tools", "gcc-mingw-w64", "dxvk", "libcap2-bin", "x11-xserver-utils"]
        if "ubuntu" in tokens:
            apt_packages.insert(3, "winetricks")
        return Distro(
            distro_id,
            distro_like,
            name,
            "apt-get",
            ["sudo", "apt-get", "install", "-y"],
            apt_packages,
            "python3-rich",
        )
    if "fedora" in tokens or "rhel" in tokens:
        return Distro(
            distro_id,
            distro_like,
            name,
            "dnf",
            ["sudo", "dnf", "install", "-y"],
            ["wine", "winetricks", "vulkan-tools", "mingw64-gcc", "mesa-demos", "xset"],
            "python3-rich",
        )
    if any(x in tokens for x in ("opensuse", "suse")):
        return Distro(
            distro_id,
            distro_like,
            name,
            "zypper",
            ["sudo", "zypper", "install", "-y"],
            ["wine", "winetricks", "vulkan-tools", "mingw64-gcc", "mesa-demo-x", "xset"],
            "python3-rich",
        )
    return None


def probe() -> dict[str, str]:
    distro = detect_distro()
    wine = shutil.which("wine")
    wineserver = find_wineserver()
    vm = vm_probe()
    return {
        "OS": distro.name if distro else platform.platform(),
        "Package manager": distro.package_manager if distro else "unsupported",
        "Kernel": platform.release(),
        "Architecture": platform.machine(),
        "Virtualization": vm["virtualization"],
        "CPU model": vm["cpu_model"],
        "GPU hint": vm["gpu_hint"],
        "Proxmox recommendation": vm["recommendation"],
        "Memory": command_output(["free", "-h"]).strip(),
        "Disk /": command_output(["df", "-h", "/"]).strip(),
        "Wine": command_output(["wine", "--version"]).strip() if wine else "missing",
        "wineserver": wineserver or "missing",
        "wineserver caps": command_output(["getcap", wineserver]).strip() if wineserver else "missing",
        "Sleep targets": command_output(["systemctl", "is-enabled", "sleep.target", "suspend.target", "hibernate.target", "hybrid-sleep.target"]).strip(),
        "OpenGL": _first_relevant_line(desktop_command_output(["glxinfo", "-B"]), ["OpenGL renderer", "OpenGL version", "Device:"]),
        "Vulkan": _first_relevant_line(command_output(["vulkaninfo", "--summary"]), ["GPU id", "deviceName", "driverName"]),
        "Interfaces": command_output(["ip", "-br", "addr"]).strip(),
        "Routes": command_output(["ip", "route"]).strip(),
        "Multicast": _ma_multicast_summary(command_output(["ip", "maddr", "show"])),
        "UFW": command_output(["sudo", "-n", "ufw", "status", "verbose"]).strip() or "not available or sudo required",
        "MA sockets": command_output(["sh", "-c", "ss -H -ulpn 2>/dev/null | grep -E '30020|3002|8080|wine|app_|gma|ma' || true"]).strip(),
    }


def vm_probe() -> dict[str, str]:
    virtualization = _virtualization_summary()
    cpu_model = _cpu_model()
    gpu_hint = _gpu_hint()
    recommendation = proxmox_recommendation(virtualization, cpu_model, gpu_hint)
    return {
        "virtualization": virtualization,
        "cpu_model": cpu_model,
        "gpu_hint": gpu_hint,
        "recommendation": recommendation,
    }


def proxmox_recommendation(virtualization: str, cpu_model: str, gpu_hint: str) -> str:
    if not _looks_like_proxmox_vm(virtualization):
        return "not a detected Proxmox/KVM VM"

    issues: list[str] = []
    if not _looks_like_host_cpu(cpu_model):
        issues.append("set Proxmox CPU type to host")
    if not _looks_like_virgl_gpu(gpu_hint):
        issues.append("set Proxmox display/GPU to VirGL")

    if not issues:
        return "OK: Proxmox CPU appears host-like and GPU appears VirGL"
    return "Proxmox VM detected: " + "; ".join(issues)


def _virtualization_summary() -> str:
    parts: list[str] = []
    systemd_detect = command_output(["systemd-detect-virt"]).strip()
    if systemd_detect:
        parts.append(systemd_detect)

    product = _read_first_existing(
        [
            Path("/sys/class/dmi/id/product_name"),
            Path("/sys/class/dmi/id/sys_vendor"),
            Path("/sys/class/dmi/id/board_vendor"),
        ]
    )
    if product:
        parts.append(product)

    return " / ".join(dict.fromkeys(parts)) or "unknown"


def _cpu_model() -> str:
    cpuinfo = Path("/proc/cpuinfo")
    if not cpuinfo.exists():
        return platform.processor() or "unknown"
    for line in cpuinfo.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.lower().startswith("model name") and ":" in line:
            return line.split(":", 1)[1].strip()
    return platform.processor() or "unknown"


def _gpu_hint() -> str:
    hints: list[str] = []
    lspci = command_output(["lspci", "-nn"])
    lines = [
        line.strip()
        for line in lspci.splitlines()
        if re.search(r"(vga|3d|display|virtio)", line, flags=re.IGNORECASE)
    ]
    if lines:
        hints.extend(lines[:8])

    opengl = _first_relevant_line(
        desktop_command_output(["glxinfo", "-B"]),
        ["OpenGL renderer", "OpenGL version", "Device:"],
    )
    if opengl != "missing":
        hints.append(opengl)
    return "\n".join(hints) if hints else "missing"


def _read_first_existing(paths: list[Path]) -> str:
    values: list[str] = []
    for path in paths:
        try:
            value = path.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if value:
            values.append(value)
    return " / ".join(dict.fromkeys(values))


def _looks_like_proxmox_vm(virtualization: str) -> bool:
    text = virtualization.lower()
    return any(token in text for token in ("kvm", "qemu", "proxmox", "standard pc"))


def _looks_like_host_cpu(cpu_model: str) -> bool:
    text = cpu_model.lower()
    if not text or text == "unknown":
        return False
    generic_markers = ("qemu virtual", "virtual cpu", "kvm", "common kvm", "tcg")
    return not any(marker in text for marker in generic_markers)


def _looks_like_virgl_gpu(gpu_hint: str) -> bool:
    text = gpu_hint.lower()
    return "virgl" in text


def _first_relevant_line(text: str, needles: list[str]) -> str:
    lines = [line.strip() for line in text.splitlines() if any(n in line for n in needles)]
    return "\n".join(lines[:8]) if lines else "missing"


def _ma_multicast_summary(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if re.search(r"236\.4|224\.0\.0\.1|ens|eth|enp|lo", line)]
    return "\n".join(lines[:40]) if lines else "missing"
