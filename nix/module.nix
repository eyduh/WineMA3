{ config, lib, pkgs, ... }:
let
  cfg = config.programs.winema3;

  knownHashesPath = ./../packages/known-hashes.json;
  knownHashesJson = builtins.fromJSON (builtins.readFile knownHashesPath);

  computedHash = if builtins ? hashFile then
    builtins.hashFile "sha256" cfg.installerPath
  else
    null;

  matchingVersions = if computedHash != null then
    lib.filter (v: knownHashesJson.versions.${v}.sha256 == computedHash) (lib.attrNames knownHashesJson.versions)
  else
    [ ];

  verifiedPackage = if cfg.installerPath != null then
    if matchingVersions == [ ] then
      throw "Installer hash ${computedHash} does not match any known version. Add it to packages/known-hashes.json."
    else
      pkgs.winema3-with-installer cfg.installerPath
  else
    cfg.package;
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

    installerPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "''/nix/store/...-grandMA3_onPC_win_v2.3.2.0.exe''";
      description = ''
        Path to the grandMA3 onPC installer in the Nix store.
        When set, the installer is baked into the Wine prefix at build time
        so grandMA3 is available immediately on first run.
        The installer hash is verified against the known-hashes registry.
        Use `nix-prefetch-url file:///path/to/installer.exe` to add it to the store.
      '';
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
    environment.systemPackages = [ verifiedPackage ];

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
