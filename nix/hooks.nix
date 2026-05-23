{ inputs, ... }:
{
  imports = [ inputs.git-hooks.flakeModule ];

  perSystem = { config, ... }: {
    checks.pre-commit = inputs.git-hooks.lib.${config.system}.run {
      src = ./.;
      hooks = {
        nixfmt.enable = true;
        rustfmt.enable = true;
        statix.enable = true;
      };
    };
  };
}
