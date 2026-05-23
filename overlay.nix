{ withSystem, inputs, ... }:
{
  flake.overlays.default =
    _final: prev:
    withSystem prev.stdenv.hostPlatform.system (
      { config, ... }:
      let
        inherit (config._module.args) craneLib wine-packages wineUnwrapped prefixBase wintrustStub registryPatches;
      in
      {
        winema3 = prev.callPackage ./packages/package.nix {
          inherit craneLib wine-packages wineUnwrapped prefixBase wintrustStub registryPatches;
        };
      }
    );
}
