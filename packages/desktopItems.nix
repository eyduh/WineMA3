{ makeDesktopItem, lib }:
{
  gma3 = makeDesktopItem rec {
    desktopName = "grandMA3 onPC";
    name = "winema3-gma3";
    exec = "winema3-gma3 %U";
    icon = "winema3-grandma3";
    type = "Application";
    terminal = false;
    categories = [ "AudioVideo" "Utility" ];
    startupWMClass = "app_system.exe";
    comment = "Start grandMA3 onPC via WineMA3";
  };
}
