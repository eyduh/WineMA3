use duct::Expression;
use std::path::Path;

pub fn make_env(expression: Expression, wine_prefix: &Path, verbose: bool) -> Expression {
    let expression = expression
        .env("WINEPREFIX", wine_prefix.display().to_string())
        .env("WINEARCH", "win64")
        .env("LANG", "en_US.UTF-8")
        .env("LC_ALL", "en_US.UTF-8")
        .env("MESA_GL_VERSION_OVERRIDE", "4.2")
        .env("MESA_GLSL_VERSION_OVERRIDE", "420")
        .env("WINEDLLOVERRIDES", "wintrust=n,b;dxgi,d3d11=n")
        .env("DXVK_LOG_LEVEL", "info");

    if verbose {
        expression
    } else {
        expression.env("WINEDEBUG", "-all,fixme-all")
    }
}
