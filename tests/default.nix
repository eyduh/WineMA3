{ inputs, ... }:
{
  perSystem = { config, pkgs, ... }:
    let
      winema3Package = config.packages.winema3;
    in
    {
      checks.test-gma3 = pkgs.testers.nixosTest {
        name = "test-gma3";
        nodes.machine = { config, pkgs, ... }: {
          imports = [ ../nix/module.nix ];
          programs.winema3.enable = true;
          programs.winema3.package = winema3Package;
          services.xserver.enable = true;
          services.displayManager.sddm.enable = true;
          services.desktopManager.plasma6.enable = true;
          system.stateVersion = "24.11";
        };
        testScript = builtins.readFile ./gma3.py;
      };
    };
}
