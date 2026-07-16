# Home Manager module for WineMA3.
#
# Home Manager can only manage user-scope state ($HOME + the user systemd
# session), so this module is a SUBSET of the NixOS module (nix/nixos-module.nix):
#
#   Reproduced here          : launcher, "grandMA3 (Wine)" menu entry, sleep
#                              inhibition (keepAwake), idle/DPMS/screensaver
#                              suppression, the WINEMA3_MANAGED marker.
#   NOT reproducible here     : opening MA-Net firewall ports and granting
#                              wineserver cap_net_raw — both require root.
#
# For the networking bits, either use the NixOS module (on NixOS) or let the
# `winema3-install` runtime installer apply them via its own sudo-gated prompts
# (on other distros). See the README.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.winema3;

  onDemand = cfg.launchMode == "on-demand";

  # Shared user-scope building blocks (also used by the NixOS module).
  common = import ./common.nix { inherit pkgs lib; };
  inherit (common) noPowerSaveScript autostartDesktop wineLauncher;

  # winema3-wrap is only meaningful here when it has something to do — i.e. when
  # keepAwake scopes the inhibit service + power settings to a launch. Unlike the
  # NixOS wrapper there is no firewall service to start (that needs root).
  needWrapper = onDemand && cfg.keepAwake;

  # On-demand wrapper: bring the user inhibit service up (and apply power
  # settings) for the duration of the run, then tear it down on exit.
  launchWrapperBin = pkgs.writeShellScriptBin "winema3-wrap" ''
    set -euo pipefail

    cleanup() {
      systemctl --user stop winema3-inhibit.service 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM HUP

    systemctl --user start winema3-inhibit.service
    ${noPowerSaveScript}

    "$@"
  '';

  wineDesktop = common.mkWineDesktop { wrap = needWrapper; };
in
{
  options.programs.winema3 = {
    enable = mkEnableOption "WineMA3 grandMA3 onPC launcher and user-scope runtime support";

    package = mkOption {
      type = types.package;
      default = pkgs.winema3 or (pkgs.callPackage ./package.nix { });
      description = "The WineMA3 package to use.";
    };

    launchMode = mkOption {
      type = types.enum [ "always" "on-demand" ];
      default = "on-demand";
      description = ''
        Controls when sleep inhibition and idle suppression are active.

        "always"    — the inhibit user service starts at login and the power
                      settings autostart entry runs on every graphical session.
                      Suited to a dedicated grandMA3 workstation.

        "on-demand" — inhibition and power settings are scoped to a grandMA3
                      launch via winema3-wrap, which the "grandMA3 (Wine)" menu
                      entry uses automatically, and torn down when it exits.

        Note: unlike the NixOS module this does NOT gate any firewall behaviour —
        Home Manager cannot manage the system firewall. See openFirewall below.
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

    home.packages = [ cfg.package wineLauncher wineDesktop ]
      ++ optional needWrapper launchWrapperBin;

    # Tell the runtime installer the launcher/desktop entry are managed here, so
    # it writes nothing into $HOME that would linger after the module is removed.
    home.sessionVariables.WINEMA3_MANAGED = "1";

    # ── Sleep inhibition (user service) ────────────────────────────────────────

    # "always" mode: Install.WantedBy starts it at login.
    # "on-demand" mode: no Install — winema3-wrap starts/stops it explicitly.
    systemd.user.services.winema3-inhibit = mkIf cfg.keepAwake {
      Unit.Description = "WineMA3 inhibit sleep/idle for grandMA3 onPC";
      Service = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=handle-lid-switch:handle-suspend-key:handle-hibernate-key:handle-power-key --who=grandMA3 --why=\"grandMA3 onPC show running\" --mode=block ${pkgs.coreutils}/bin/sleep infinity";
      };
      Install = mkIf (!onDemand) { WantedBy = [ "default.target" ]; };
    };

    # ── Idle-blanking suppression (always mode only) ───────────────────────────

    # In "on-demand" mode the power script is called by winema3-wrap instead.
    xdg.configFile."autostart/winema3-no-power-save.desktop" =
      mkIf (cfg.keepAwake && !onDemand) {
        source = autostartDesktop;
      };

    # MA-Net networking (firewall ports + wineserver cap_net_raw) is privileged
    # and cannot be configured from Home Manager. Remind the user once.
    warnings = optional cfg.enable ''
      programs.winema3 (Home Manager) manages the launcher, menu entry, and
      keep-awake behaviour only. MA-Net networking — opening UDP 30020 / TCP 8080
      and 30022-30040, and granting wineserver cap_net_raw — needs root: use the
      NixOS module on NixOS, or let `winema3-install` apply them via its prompts.
    '';
  };
}
