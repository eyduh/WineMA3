{ config, lib, pkgs, ... }:
let
  cfg = config.programs.winema3;
in
{
  options.programs.winema3 = {
    enable = lib.mkEnableOption "WineMA3 grandMA3 onPC support";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.winema3;
      defaultText = lib.literalExpression "pkgs.winema3";
      description = "The WineMA3 package to use.";
    };

    enableNetworking = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable MA-Net firewall rules and wineserver capabilities.";
    };

    enablePowerSaving = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable OS sleep and display blanking for MA workstations.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # MA-Net firewall rules
    networking.firewall = lib.mkIf cfg.enableNetworking {
      allowedUDPPorts = [ 30020 ];
      allowedTCPPorts = [ 8080 ] ++ builtins.genList (x: 30022 + x) 19; # 30022-30040
    };

    # wineserver capabilities for raw multicast sockets
    security.wrappers.wineserver = lib.mkIf cfg.enableNetworking {
      setuid = false;
      owner = "root";
      group = "root";
      capabilities = "cap_net_raw=ep";
      source = "${pkgs.wineWow64Packages.full}/bin/wineserver";
    };

    # Power management: disable sleep
    systemd.sleep.settings = lib.mkIf cfg.enablePowerSaving {
      Sleep = {
        AllowSuspend = "no";
        AllowHibernation = "no";
        AllowHybridSleep = "no";
        AllowSuspendThenHibernate = "no";
      };
    };

    services.xserver = lib.mkIf cfg.enablePowerSaving {
      serverFlagsSection = lib.mkDefault ''
        Option "BlankTime" "0"
        Option "StandbyTime" "0"
        Option "SuspendTime" "0"
        Option "OffTime" "0"
      '';
      monitorSection = lib.mkDefault ''
        Identifier "WineMA3-NoPowerSave"
        Option "DPMS" "false"
      '';
    };
  };
}
