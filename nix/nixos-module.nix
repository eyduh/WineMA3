{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.winema3;

  noPowerSaveScript = pkgs.writeShellScript "winema3-no-power-save" ''
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
in
{
  options.programs.winema3 = {
    enable = mkEnableOption "WineMA3 grandMA3 onPC installer and runtime support";

    package = mkOption {
      type = types.package;
      default = pkgs.winema3 or (pkgs.callPackage ./package.nix { });
      description = "The WineMA3 package to use.";
    };

    firewall.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to open MA-Net firewall ports.
        UDP 30020 (multicast), TCP 8080 (web remote), TCP 30022-30040 (MA-Net3 alternate TCP).
      '';
    };

    wineserver.capNetRaw = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to wrap wineserver with cap_net_raw capability.
        This is required for MA-Net multicast networking under Wine.
      '';
    };

    powerSaving.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to install a user-level systemd inhibit service and idle script.
        The inhibit service is started automatically when gma3 is launched and
        stops when gma3 exits, scoping sleep inhibition to MA runtime only.
        The idle script runs once per graphical login to disable screen blanking.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    networking.firewall = mkIf cfg.firewall.enable {
      allowedUDPPorts = [ 30020 ];
      allowedTCPPorts = [ 8080 ] ++ builtins.genList (n: 30022 + n) 19;
    };

    security.wrappers.wineserver = mkIf cfg.wineserver.capNetRaw {
      setuid = false;
      owner = "root";
      group = "root";
      capabilities = "cap_net_raw=ep";
      source = "${pkgs.wineWow64Packages.full}/bin/wineserver";
    };

    systemd.user.services.winema3-inhibit = mkIf cfg.powerSaving.enable {
      description = "WineMA3 inhibit sleep/idle for grandMA3 onPC";
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=handle-lid-switch:handle-suspend-key:handle-hibernate-key:handle-power-key --who=grandMA3 --why=\"grandMA3 onPC show running\" --mode=block ${pkgs.coreutils}/bin/sleep infinity";
      };
    };

    environment.etc."xdg/autostart/winema3-no-power-save.desktop" = mkIf cfg.powerSaving.enable {
      source = autostartDesktop;
    };
  };
}
