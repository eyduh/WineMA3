{ withSystem, inputs, ... }:
{
  flake.overlays.default =
    _final: prev:
    withSystem prev.stdenv.hostPlatform.system (
      { config, ... }:
      let
        inherit (config._module.args) craneLib stdPath wine-packages wineUnwrapped prefixBase wintrustStub registryPatches runner desktopItems icons;
        prefixWithGma3 = installer:
          prev.callPackage ./packages/prefixWithGma3.nix {
            inherit wine-packages prefixBase wintrustStub registryPatches;
            inherit installer;
          };
        runnerWithPrefix = customPrefix:
          prev.callPackage ./packages/runner/package.nix {
            inherit craneLib stdPath wine-packages registryPatches;
            prefixBase = customPrefix;
          };
        packageWithPrefix = customPrefix:
          prev.symlinkJoin {
            name = "winema3";
            paths = [
              (runnerWithPrefix customPrefix)
              desktopItems.gma3
              icons.iconPackage
            ];
          };
      in
      {
        winema3 = prev.callPackage ./packages/package.nix {
          inherit craneLib wine-packages wineUnwrapped prefixBase wintrustStub registryPatches;
        };
        winema3-with-installer = installer: packageWithPrefix (prefixWithGma3 installer);
      }
    );
}
