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

  # Placed in PATH when launchMode = "on-demand". The shipped "grandMA3 (Wine)"
  # .desktop entry runs its launcher through this wrapper automatically:
  #   Exec=winema3-wrap gma3-wine
  # Starts the firewall and inhibit services, applies power settings, waits for
  # MA3 to exit, then tears everything back down.
  launchWrapperBin = pkgs.writeShellScriptBin "winema3-wrap" ''
    set -euo pipefail

    cleanup() {
      ${optionalString cfg.keepAwake ''
        systemctl --user stop winema3-inhibit.service 2>/dev/null || true
      ''}
      ${optionalString cfg.openFirewall ''
        systemctl stop winema3-firewall.service 2>/dev/null || true
      ''}
    }
    trap cleanup EXIT INT TERM HUP

    ${optionalString cfg.openFirewall ''
      systemctl start winema3-firewall.service
    ''}
    ${optionalString cfg.keepAwake ''
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

  wineDesktop = pkgs.makeDesktopItem {
    name = "grandMA3-wine";
    desktopName = "grandMA3 (Wine)";
    genericName = "Lighting Console";
    comment = "grandMA3 onPC via Wine (WineMA3)";
    # Reference the binaries by name (they're in systemPackages, hence on the
    # session PATH) rather than by absolute store path — this keeps the entry
    # valid across rebuilds and avoids stranding on a garbage-collected path.
    # In on-demand mode wrap through winema3-wrap so launching from the menu
    # opens the MA-Net firewall ports (and starts inhibit) for the session and
    # closes them again on exit. Without this the console can't reach the PC.
    exec = (optionalString onDemand "winema3-wrap ") + "gma3-wine";
    categories = [ "AudioVideo" ];
    keywords = [ "grandMA3" "MA3" "lighting" "onPC" "wine" ];
    startupWMClass = "app_system.exe";
    # Run in a terminal: launching from a Terminal=false .desktop lands the
    # process in a transient KDE app scope whose control-group teardown reaps
    # the console (and, with winema3-wrap in front, the launch fails outright).
    # A real terminal sidesteps that and reliably keeps the session alive.
    terminal = true;
  };
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
                      exits. The shipped "grandMA3 (Wine)" .desktop entry is
                      wrapped with winema3-wrap automatically, so launching from
                      the menu opens the ports for the session and closes them on
                      exit. A polkit rule permits wheel-group users to manage the
                      winema3-firewall system unit without a password prompt.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to open the MA-Net firewall ports (UDP 30020, TCP 8080 and 30022-30040).
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

    keepAwake = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to keep the machine awake while grandMA3 is running by installing
        sleep inhibition and idle/screen-blanking suppression. Enabling this
        DISABLES power saving (it does not turn power saving on) so a running show
        never suspends or blanks mid-cue.
        In "always" mode the inhibit service starts at login and the power
        settings script runs on every graphical session start.
        In "on-demand" mode both are scoped to the grandMA3 session via winema3-wrap.
      '';
    };
  };

  config = mkIf cfg.enable {

    environment.systemPackages = [ cfg.package wineLauncher wineDesktop ]
      ++ optional onDemand launchWrapperBin;

    # Tell the runtime installer the module owns the launcher/desktop entry, so
    # it writes nothing into $HOME (which would linger after module removal).
    environment.sessionVariables.WINEMA3_MANAGED = "1";

    # ── Firewall ──────────────────────────────────────────────────────────────

    # Static rules for "always" mode.
    networking.firewall = mkIf (cfg.openFirewall && !onDemand) {
      allowedUDPPorts = [ 30020 ];
      allowedTCPPorts = [ 8080 ] ++ builtins.genList (n: 30022 + n) 19;
    };

    # Dynamic system service for "on-demand" mode: insert accept rules directly
    # into the live nixos-fw chain around each MA3 session, and remove them on
    # stop. A separate nftables table does NOT work — its accept is overridden
    # by the nixos-fw drop, because across base chains on the same hook a drop
    # verdict is terminal while an accept only passes to the next chain. So the
    # ports must be opened in nixos-fw itself. Requires the iptables backend
    # (see the assertion below); use launchMode = "always" on nftables hosts.
    systemd.services.winema3-firewall = mkIf (cfg.openFirewall && onDemand) {
      description = "WineMA3 firewall rules for grandMA3 onPC";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "winema3-fw-start" ''
          ${pkgs.iptables}/bin/iptables -I nixos-fw -p udp --dport 30020 -j nixos-fw-accept
          ${pkgs.iptables}/bin/iptables -I nixos-fw -p tcp -m multiport --dports 8080,30022:30040 -j nixos-fw-accept
        '';
        ExecStop = pkgs.writeShellScript "winema3-fw-stop" ''
          ${pkgs.iptables}/bin/iptables -D nixos-fw -p udp --dport 30020 -j nixos-fw-accept 2>/dev/null || true
          ${pkgs.iptables}/bin/iptables -D nixos-fw -p tcp -m multiport --dports 8080,30022:30040 -j nixos-fw-accept 2>/dev/null || true
        '';
      };
    };

    assertions = [
      {
        assertion = !(cfg.openFirewall && onDemand) || !config.networking.nftables.enable;
        message = ''
          programs.winema3: on-demand openFirewall supports the iptables firewall
          backend only (it edits the nixos-fw chain at runtime). Either set
          networking.nftables.enable = false, or use launchMode = "always" to get
          static declarative firewall rules instead.
        '';
      }
    ];

    # Permit wheel-group users to start/stop the firewall unit without a prompt.
    security.polkit.extraConfig = mkIf (cfg.openFirewall && onDemand) ''
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
    systemd.user.services.winema3-inhibit = mkIf cfg.keepAwake {
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
      mkIf (cfg.keepAwake && !onDemand) {
        source = autostartDesktop;
      };
  };
}
