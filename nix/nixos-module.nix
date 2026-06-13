{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.winema3;

  onDemand = cfg.launchMode == "on-demand";

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

  # Placed in PATH when launchMode = "on-demand".
  # The grandMA3 .desktop Exec line should read:
  #   Exec=winema3-wrap /path/to/grandma3-launcher %U
  # Starts the firewall and inhibit services, applies power settings, waits for
  # MA3 to exit, then tears everything back down.
  launchWrapperBin = pkgs.writeShellScriptBin "winema3-wrap" ''
    set -euo pipefail

    cleanup() {
      ${optionalString cfg.powerSaving.enable ''
        systemctl --user stop winema3-inhibit.service 2>/dev/null || true
      ''}
      ${optionalString cfg.firewall.enable ''
        systemctl stop winema3-firewall.service 2>/dev/null || true
      ''}
    }
    trap cleanup EXIT INT TERM HUP

    ${optionalString cfg.firewall.enable ''
      systemctl start winema3-firewall.service
    ''}
    ${optionalString cfg.powerSaving.enable ''
      systemctl --user start winema3-inhibit.service
      ${noPowerSaveScript}
    ''}

    "$@"
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

    launchMode = mkOption {
      type = types.enum [ "always" "on-demand" ];
      default = "on-demand";
      description = ''
        Controls when firewall ports are opened and sleep inhibition is active.

        "always"    — ports open and inhibit service running at all times.
                      Suited to a dedicated grandMA3 workstation.

        "on-demand" — services start when grandMA3 is launched and stop when it
                      exits. Requires wrapping the grandMA3 .desktop Exec with
                      winema3-wrap:
                        Exec=winema3-wrap /path/to/grandma3-launcher %U
                      A polkit rule permits wheel-group users to manage the
                      winema3-firewall system unit without a password prompt.
      '';
    };

    firewall.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to manage MA-Net firewall ports (UDP 30020, TCP 8080 and 30022-30040).
        In "always" mode these are static NixOS firewall rules.
        In "on-demand" mode a system service opens/closes them around each MA3 session
        by adding and removing a dedicated nftables table (inet winema3).
      '';
    };

    wineserver.capNetRaw = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to wrap wineserver with cap_net_raw.
        Required for MA-Net multicast networking under Wine.
      '';
    };

    powerSaving.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to install sleep inhibition and idle-blanking suppression.
        In "always" mode the inhibit service starts at login and the power
        settings script runs on every graphical session start.
        In "on-demand" mode both are scoped to the grandMA3 session via winema3-wrap.
      '';
    };
  };

  config = mkIf cfg.enable {

    environment.systemPackages = [ cfg.package ]
      ++ optional onDemand launchWrapperBin;

    # ── Firewall ──────────────────────────────────────────────────────────────

    # Static rules for "always" mode.
    networking.firewall = mkIf (cfg.firewall.enable && !onDemand) {
      allowedUDPPorts = [ 30020 ];
      allowedTCPPorts = [ 8080 ] ++ builtins.genList (n: 30022 + n) 19;
    };

    # Dynamic system service for "on-demand" mode.
    # Uses its own nftables table so it never touches the nixos-fw ruleset —
    # the whole table is atomically dropped on stop.
    systemd.services.winema3-firewall = mkIf (cfg.firewall.enable && onDemand) {
      description = "WineMA3 firewall rules for grandMA3 onPC";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "winema3-fw-start" ''
          ${pkgs.nftables}/bin/nft add table inet winema3
          ${pkgs.nftables}/bin/nft add chain inet winema3 input \
            '{ type filter hook input priority -1; policy accept; }'
          ${pkgs.nftables}/bin/nft add rule inet winema3 input \
            tcp dport { 8080, 30022-30040 } accept
          ${pkgs.nftables}/bin/nft add rule inet winema3 input \
            udp dport 30020 accept
        '';
        ExecStop = pkgs.writeShellScript "winema3-fw-stop" ''
          ${pkgs.nftables}/bin/nft delete table inet winema3 2>/dev/null || true
        '';
      };
    };

    # Permit wheel-group users to start/stop the firewall unit without a prompt.
    security.polkit.extraConfig = mkIf (cfg.firewall.enable && onDemand) ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") === "winema3-firewall.service" &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';

    # ── Wine capabilities ─────────────────────────────────────────────────────

    security.wrappers.wineserver = mkIf cfg.wineserver.capNetRaw {
      setuid = false;
      owner = "root";
      group = "root";
      capabilities = "cap_net_raw=ep";
      source = "${pkgs.wineWow64Packages.full}/bin/wineserver";
    };

    # ── Sleep inhibition ──────────────────────────────────────────────────────

    # "always" mode: wantedBy causes it to start at login.
    # "on-demand" mode: no wantedBy — winema3-wrap starts/stops it explicitly.
    systemd.user.services.winema3-inhibit = mkIf cfg.powerSaving.enable {
      description = "WineMA3 inhibit sleep/idle for grandMA3 onPC";
      wantedBy = optional (!onDemand) "default.target";
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=handle-lid-switch:handle-suspend-key:handle-hibernate-key:handle-power-key --who=grandMA3 --why=\"grandMA3 onPC show running\" --mode=block ${pkgs.coreutils}/bin/sleep infinity";
      };
    };

    # ── Idle-blanking suppression (always mode only) ───────────────────────────

    # In "on-demand" mode the power script is called by winema3-wrap instead.
    environment.etc."xdg/autostart/winema3-no-power-save.desktop" =
      mkIf (cfg.powerSaving.enable && !onDemand) {
        source = autostartDesktop;
      };
  };
}
