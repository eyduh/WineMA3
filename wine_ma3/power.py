"""Power saving and idle blanking controls for MA workstations."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

from .system import run


SLEEP_CONF = """[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
"""

XORG_NO_BLANK_CONF = """Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "Monitor"
    Identifier "WineMA3-NoPowerSave"
    Option "DPMS" "false"
EndSection
"""

NO_POWER_SAVE_SCRIPT = """#!/usr/bin/env sh
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

if command -v xset >/dev/null 2>&1; then
  xset s off 2>/dev/null || true
  xset s noblank 2>/dev/null || true
  xset s 0 0 2>/dev/null || true
  xset -dpms 2>/dev/null || true
fi

if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
fi

if command -v xfconf-query >/dev/null 2>&1; then
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -t int -s 0 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -t int -s 0 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -t bool -s false 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -t int -s 0 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -t int -s 0 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-sleep -t int -s 0 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-off -t int -s 0 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-ac -t int -s 14 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-battery -t int -s 14 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -t bool -s false 2>/dev/null || true
  xfconf-query -n -c xfce4-power-manager -p /xfce4-power-manager/presentation-mode -t bool -s true 2>/dev/null || true
  xfconf-query -n -c xfce4-screensaver -p /saver/enabled -t bool -s false 2>/dev/null || true
  xfconf-query -n -c xfce4-screensaver -p /saver/idle-activation-enabled -t bool -s false 2>/dev/null || true
  xfconf-query -n -c xfce4-screensaver -p /lock/enabled -t bool -s false 2>/dev/null || true
  xfconf-query -n -c xfce4-screensaver -p /lock/saver-activation/enabled -t bool -s false 2>/dev/null || true
  xfconf-query -n -c xfce4-screensaver -p /lock/sleep-activation/enabled -t bool -s false 2>/dev/null || true
fi

for kwriteconfig in kwriteconfig6 kwriteconfig5; do
  if command -v "$kwriteconfig" >/dev/null 2>&1; then
    "$kwriteconfig" --file kscreenlockerrc --group Daemon --key Autolock false 2>/dev/null || true
    "$kwriteconfig" --file kscreenlockerrc --group Daemon --key LockOnResume false 2>/dev/null || true
    "$kwriteconfig" --file kscreenlockerrc --group Daemon --key Timeout 0 2>/dev/null || true
    for profile in AC Battery LowBattery; do
      "$kwriteconfig" --file powermanagementprofilesrc --group "$profile" --group DimDisplay --key idleTime 0 2>/dev/null || true
      "$kwriteconfig" --file powermanagementprofilesrc --group "$profile" --group DPMSControl --key idleTime 0 2>/dev/null || true
      "$kwriteconfig" --file powermanagementprofilesrc --group "$profile" --group SuspendSession --key idleTime 0 2>/dev/null || true
      "$kwriteconfig" --file powerdevilrc --group "$profile" --group Display --key TurnOffDisplayIdleTimeoutSec 0 2>/dev/null || true
    done
  fi
done

for qdbus in qdbus6 qdbus-qt6 qdbus qdbus-qt5; do
  if command -v "$qdbus" >/dev/null 2>&1; then
    "$qdbus" org.freedesktop.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.reparseConfiguration 2>/dev/null || true
    "$qdbus" org.freedesktop.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.refreshStatus 2>/dev/null || true
    "$qdbus" org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.reparseConfiguration 2>/dev/null || true
    "$qdbus" org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.refreshStatus 2>/dev/null || true
    break
  fi
done

if command -v xscreensaver-command >/dev/null 2>&1; then
  xscreensaver-command -exit 2>/dev/null || true
fi
pkill -x xscreensaver 2>/dev/null || true
"""

AUTOSTART_DESKTOP = """[Desktop Entry]
Type=Application
Name=WineMA3 No Power Saving
Comment=Disable suspend, screen blanking, and DPMS for grandMA3 onPC
Exec=sh -c "$HOME/.local/bin/winema3-no-power-save"
OnlyShowIn=GNOME;KDE;XFCE;LXDE;LXQt;MATE;Cinnamon;
X-GNOME-Autostart-enabled=true
"""


def disable_power_saving() -> None:
    """Disable OS sleep and desktop idle blanking for the current MA workstation."""
    _install_user_systemd_inhibit_service()
    _install_user_idle_script()
    _install_user_idle_service()
    _run_user_idle_script_now()


def _install_user_systemd_inhibit_service() -> None:
    """Create a user systemd service that inhibits sleep via systemd-inhibit."""
    service_dir = Path.home() / ".config/systemd/user"
    service_dir.mkdir(parents=True, exist_ok=True)
    service_file = service_dir / "winema3-inhibit.service"
    service_file.write_text(
        """[Unit]
Description=WineMA3 inhibit sleep/idle for grandMA3 onPC

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/bin/systemd-inhibit --what=handle-lid-switch:handle-suspend-key:handle-hibernate-key:handle-power-key --who=grandMA3 --why="grandMA3 onPC show running" --mode=block sleep infinity

[Install]
WantedBy=default.target
""",
        encoding="utf-8",
    )
    run(["systemctl", "--user", "daemon-reload"], check=False)
    run(["systemctl", "--user", "enable", "--now", "winema3-inhibit.service"], check=False)


def _install_root_file(content: str, target: Path) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(content)
        temp_name = handle.name
    try:
        run(["sudo", "install", "-D", "-m", "0644", temp_name, str(target)], check=True)
    finally:
        Path(temp_name).unlink(missing_ok=True)


def _install_user_idle_script() -> None:
    local_bin = Path.home() / ".local/bin"
    local_bin.mkdir(parents=True, exist_ok=True)
    script = local_bin / "winema3-no-power-save"
    script.write_text(NO_POWER_SAVE_SCRIPT, encoding="utf-8")
    script.chmod(0o755)

    autostart_dir = Path.home() / ".config/autostart"
    autostart_dir.mkdir(parents=True, exist_ok=True)
    (autostart_dir / "winema3-no-power-save.desktop").write_text(AUTOSTART_DESKTOP, encoding="utf-8")


def _remove_old_user_inhibit_service() -> None:
    service = Path.home() / ".config/systemd/user/winema3-inhibit.service"
    if not service.exists():
        return
    env = _desktop_env()
    run(["systemctl", "--user", "disable", "--now", "winema3-inhibit.service"], env=env)
    service.unlink(missing_ok=True)
    run(["systemctl", "--user", "daemon-reload"], env=env)


def _run_user_idle_script_now() -> None:
    script = Path.home() / ".local/bin/winema3-no-power-save"
    if not script.exists():
        return
    env = _desktop_env()
    run([str(script)], env=env)


def _desktop_env() -> dict[str, str]:
    env = os.environ.copy()
    runtime_dir = env.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    env.setdefault("DISPLAY", ":0")
    env.setdefault("XDG_RUNTIME_DIR", runtime_dir)
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={runtime_dir}/bus")
    return env
