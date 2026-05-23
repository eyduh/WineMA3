pub fn run_probe() {
    println!("WineMA3 System Probe");
    println!("====================");
    println!();
    println!("OS:          {}", std::env::consts::OS);
    println!("Arch:        {}", std::env::consts::ARCH);
    println!();
    println!("WINE:        {}", crate::WINE);
    println!("WINESERVER:  {}", crate::WINESERVER);
    println!("WINETRICKS:  {}", crate::WINETRICKS);
    println!();
    println!("LOWER_DIR:   {}", crate::LOWER_DIR.display());
}
