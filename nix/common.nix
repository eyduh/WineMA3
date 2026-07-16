# Shared building blocks used by both the NixOS module (nix/nixos-module.nix)
# and the Home Manager module (nix/home-module.nix). Everything here is
# user-scope and unprivileged, so it is identical between the two modules.
{ pkgs, lib }:

let
  inherit (lib) optionalString;
in
rec {
  # Applies "no power saving" settings across GNOME, XFCE, KDE, and X11 so a
  # running show never suspends, blanks, or locks. Pure user-session commands.
  noPowerSaveScript = pkgs.writeShellScript "winema3-no-power-save" ''
    export DISPLAY="''${DISPLAY:-:0}"
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

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
  '';

  autostartDesktop = pkgs.writeText "winema3-no-power-save.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=WineMA3 No Power Saving
    Comment=Disable suspend, screen blanking, and DPMS for grandMA3 onPC
    Exec=${noPowerSaveScript}
    OnlyShowIn=GNOME;KDE;XFCE;LXDE;LXQt;MATE;Cinnamon;
    X-GNOME-Autostart-enabled=true
  '';

  # Declarative launcher: discovers the newest Wine prefix under XDG at runtime
  # and starts grandMA3 onPC. Named gma3-wine so it never collides with (or
  # shadows) the native grandma3-nix `gma3`. Shipped via the module so removing
  # the module removes it — nothing lingers in $HOME.
  wineLauncher = pkgs.writeShellScriptBin "gma3-wine" ''
    set -u
    export DISPLAY="''${DISPLAY:-:0}"
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

    base="''${XDG_DATA_HOME:-$HOME/.local/share}/winema3"
    prefix=$(${pkgs.coreutils}/bin/ls -d "$base"/gma3_* 2>/dev/null | ${pkgs.coreutils}/bin/sort -V | ${pkgs.coreutils}/bin/tail -1 || true)
    if [ -z "''${prefix:-}" ]; then
      echo "No WineMA3 prefix found under $base — run the installer first." >&2
      exit 1
    fi
    ver=$(${pkgs.coreutils}/bin/basename "$prefix")

    export WINEPREFIX="$prefix"
    export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
    export MESA_GL_VERSION_OVERRIDE=4.2 MESA_GLSL_VERSION_OVERRIDE=420
    export WINEDLLOVERRIDES='wintrust=n,b;dxgi,d3d11=n'

    cd "$prefix/drive_c/Program Files/MALightingTechnology/$ver/bin" || exit 1

    # app_system.exe is a launcher: it spawns the real console process and the
    # initial wine client returns early. When started from the KDE .desktop entry
    # (Terminal=false) the app runs inside a transient app-*@.service scope, so
    # once this launcher's main PID exits, KillMode=control-group reaps the
    # console — it dies ~10s after the requirement dialog. Running in a terminal
    # hid this because there was no cgroup teardown.
    #
    # Run wine in the foreground (guarantees the server is up when it returns),
    # then block on `wineserver -w`, which waits until every wine process in the
    # prefix has exited. That keeps this launcher — hence the scope's main PID —
    # alive for the whole session without needing a terminal.
    ${pkgs.wineWow64Packages.full}/bin/wine "''${WINEMA3_APP:-app_system.exe}" HOSTTYPE=onPC "$@" || true
    exec ${pkgs.wineWow64Packages.full}/bin/wineserver -w
  '';

  # The "grandMA3 (Wine)" menu entry. Pass wrap = true to run the launcher
  # through winema3-wrap (on-demand mode) so launching from the menu brings the
  # per-session services up and down around the run.
  mkWineDesktop = { wrap ? false }: pkgs.makeDesktopItem {
    name = "grandMA3-wine";
    desktopName = "grandMA3 (Wine)";
    genericName = "Lighting Console";
    comment = "grandMA3 onPC via Wine (WineMA3)";
    # Reference the binaries by name (they're on the session PATH via the
    # package set) rather than by absolute store path — this keeps the entry
    # valid across rebuilds and avoids stranding on a garbage-collected path.
    # In on-demand mode wrap through winema3-wrap so launching from the menu
    # opens the MA-Net firewall ports (and starts inhibit) for the session and
    # closes them again on exit. Without this the console can't reach the PC.
    exec = (optionalString wrap "winema3-wrap ") + "gma3-wine";
    categories = [ "AudioVideo" ];
    keywords = [ "grandMA3" "MA3" "lighting" "onPC" "wine" ];
    startupWMClass = "app_system.exe";
    # Run in a terminal: launching from a Terminal=false .desktop lands the
    # process in a transient KDE app scope whose control-group teardown reaps
    # the console (and, with winema3-wrap in front, the launch fails outright).
    # A real terminal sidesteps that and reliably keeps the session alive.
    terminal = true;
  };
}
