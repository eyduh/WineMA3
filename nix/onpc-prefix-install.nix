# Idempotent helper: copy a prebuilt grandMA3 onPC Wine prefix from the Nix
# store into the writable XDG location the launcher reads.
{ lib
, writeShellApplication
, coreutils
}:

{ prefix
}:

let
  inherit (prefix) installDir;
  storePath = "${prefix}/${installDir}";
in

writeShellApplication {
  name = "winema3-install-prefix";
  runtimeInputs = [ coreutils ];
  text = ''
    dataHome="''${XDG_DATA_HOME:-$HOME/.local/share}"
    dest="$dataHome/winema3"
    target="$dest/${installDir}"
    marker="$dest/.${installDir}.src"

    mkdir -p "$dest"

    if [ -r "$marker" ] && [ "$(cat "$marker")" = "${storePath}" ] && [ -d "$target" ]; then
      echo "grandMA3 onPC prefix already up to date at $target"
      exit 0
    fi

    echo "Installing/updating grandMA3 onPC prefix at $target ..."
    rm -rf "$target"
    cp -r --no-preserve=mode,ownership "${storePath}" "$target"
    chmod -R u+w "$target"
    printf '%s' "${storePath}" > "$marker"
    echo "Done. Launch with gma3-wine."
  '';
}
