{ withSystem, inputs, ... }:
{
  flake.overlays.default =
    _final: prev:
    withSystem prev.stdenv.hostPlatform.system (
      { config, ... }:
      let
        inherit (config._module.args) craneLib wine-packages wineUnwrapped prefixBase prefixWithGma3 wintrustStub registryPatches;
      in
      {
        winema3 = prev.callPackage ./packages/package.nix {
          inherit craneLib wine-packages wineUnwrapped prefixBase wintrustStub registryPatches;
        };
        winema3-prefix-with-gma3 = prefixWithGma3;
      }
    );
}
