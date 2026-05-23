use std::fs;
use std::io;
use std::path::Path;

pub const LATEST_REVISION: u32 = 1;

pub fn read_revision(prefix: &Path) -> u32 {
    let path = prefix.join(".revision");
    match fs::read_to_string(&path) {
        Ok(text) => text.trim().parse().unwrap_or(0),
        Err(_) => 0,
    }
}

pub fn write_revision(prefix: &Path, revision: u32) -> io::Result<()> {
    fs::write(prefix.join(".revision"), revision.to_string())
}

pub fn perform_migrations(prefix: &Path) -> anyhow::Result<()> {
    let current = read_revision(prefix);
    if current < 1 {
        // Initial revision: ensure wintrust registry is set
        // This is handled by the prefix build, so nothing to do at runtime
    }
    write_revision(prefix, LATEST_REVISION)?;
    Ok(())
}
