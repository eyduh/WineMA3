{ requireFile }:
let
  # Set these after running nix-prefetch-url on your installer (EXE or ZIP).
  # Example:
  #   nix-prefetch-url file:///path/to/grandMA3_onPC_win_v2.3.2.0.exe
  name = "grandMA3_onPC_win_v2.3.2.0.exe";
  sha256 = null; # e.g. "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
in
if sha256 == null then
  { installer = null; }
else
  {
    installer = requireFile {
      inherit name sha256;
      url = "https://www.malighting.com/downloads/";
      message = ''
        grandMA3 onPC installer is not freely redistributable.

        1. Download the installer (EXE or ZIP) from https://www.malighting.com/downloads/
        2. Run: nix-prefetch-url file:///path/to/grandMA3_onPC_win_vX.Y.Z.W.exe
           Or:  nix-prefetch-url file:///path/to/grandMA3_onPC_win_vX.Y.Z.W.zip
        3. Paste the resulting sha256 into packages/sources.nix
      '';
    };
  }
