{ requireFile, runCommand, writeText, lib }:
{
  # User must download the installer from MA Lighting and prefetch it:
  #   nix-prefetch-url file:///path/to/grandMA3_onPC_win_vX.Y.Z.W.exe
  # Then provide the resulting sha256 here.
  installer = requireFile {
    name = "grandMA3_onPC_win_v2.3.2.0.exe";
    url = "https://www.malighting.com/downloads/";
    sha256 = "0000000000000000000000000000000000000000000000000000";
    message = ''
      grandMA3 onPC installer is not freely redistributable.

      1. Download the installer from https://www.malighting.com/downloads/
      2. Run: nix-prefetch-url file:///path/to/grandMA3_onPC_win_vX.Y.Z.W.exe
      3. Paste the resulting sha256 into packages/sources.nix
    '';
  };
}
