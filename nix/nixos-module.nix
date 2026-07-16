{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.winema3;

  onDemand = cfg.launchMode == "on-demand";

  # Shared user-scope building blocks (also used by the Home Manager module).
  common = import ./common.nix { inherit pkgs lib; };
  inherit (common) noPowerSaveScript autostartDesktop wineLauncher;

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

  wineDesktop = common.mkWineDesktop { wrap = onDemand; };
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
