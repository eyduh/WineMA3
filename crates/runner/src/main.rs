use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nix::mount::{mount, umount, MsFlags};
use nix::sched::{unshare, CloneFlags};
use nix::unistd::{fork, getgid, getuid, ForkResult};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use duct::cmd;
use tracing::{error, info, Level};
use tracing_subscriber::FmtSubscriber;

pub(crate) const WINE: &str = env!("WINE");
pub(crate) const WINESERVER: &str = env!("WINESERVER");
pub(crate) const WINETRICKS: &str = env!("WINETRICKS");
pub(crate) const FUSE_OVERLAYFS: &str = env!("FUSE_OVERLAYFS");
pub(crate) const GNUTAR: &str = env!("GNUTAR");
pub(crate) const ZENITY: &str = env!("ZENITY");
pub(crate) const RSYNC: &str = env!("RSYNC");
pub(crate) const DXVK: &str = env!("DXVK");
pub(crate) const WINTRUST_STUB: &str = env!("WINTRUST_STUB");
pub(crate) static LOWER_DIR: LazyLock<PathBuf> = LazyLock::new(|| PathBuf::from(env!("LOWER_DIR")));

static KNOWN_HASHES_JSON: &str = match option_env!("KNOWN_HASHES") {
    Some(v) => v,
    None => r#"{"versions":{}}"#,
};

const MOUNT_FAIL_STATUS: i32 = 111;

#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Arguments {
    /// Make Wine far more verbose.
    #[arg(long)]
    verbose: bool,

    /// Specified tool to use. If none matches, defaults to grandMA3.
    #[command(subcommand)]
    subcommand: Option<Program>,

    /// Arguments for grandMA3 application
    #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
    gma3_arguments: Vec<String>,
}

#[derive(Subcommand, Debug)]
enum Program {
    Wine { arguments: Vec<String> },
    Winetricks { arguments: Vec<String> },
    Wineboot { arguments: Vec<String> },
    Wineserver { arguments: Vec<String> },
    Probe,
    Install { path: PathBuf },
}

#[derive(Debug)]
struct Paths {
    upper: PathBuf,
    work: PathBuf,
    wine_prefix: PathBuf,
}

impl Paths {
    fn ensure_created(&self) -> Result<()> {
        for path in [&self.upper, &self.work, &self.wine_prefix] {
            if path.exists() {
                let nested = path.join("work");
                if nested.exists() {
                    fs::set_permissions(&nested, fs::Permissions::from_mode(0o700))?;
                    fs::remove_dir_all(&nested)?;
                }
            }
            fs::create_dir_all(path)?;
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
struct Registry {
    versions: HashMap<String, VersionInfo>,
}

#[derive(Debug, Deserialize)]
struct VersionInfo {
    sha256: String,
    filename: String,
}

fn load_registry() -> Result<Registry> {
    let registry: Registry = serde_json::from_str(KNOWN_HASHES_JSON)
        .context("Failed to parse known-hashes registry")?;
    Ok(registry)
}

fn compute_file_hash(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    let result = hasher.finalize();
    Ok(hex::encode(result))
}

fn verify_installer(path: &Path) -> Result<Option<String>> {
    let hash = compute_file_hash(path)?;
    let registry = load_registry()?;

    for (version, info) in &registry.versions {
        if info.sha256 == hash {
            return Ok(Some(version.clone()));
        }
    }

    eprintln!("Unknown installer hash: {}", hash);
    eprintln!("This installer is not in the known-hashes registry.");
    eprintln!("Add it to packages/known-hashes.json and rebuild, or verify the file is correct.");
    Ok(None)
}

fn extract_installer(path: &Path) -> Result<PathBuf> {
    let path_str = path.to_string_lossy();
    if path_str.ends_with(".zip") {
        let tmp_dir = env::temp_dir().join(format!("winema3-extract-{}", std::process::id()));
        fs::create_dir_all(&tmp_dir)?;
        println!("Extracting ZIP archive...");
        cmd!("unzip", "-q", path, "-d", &tmp_dir).run()?;
        let exe = walkdir::WalkDir::new(&tmp_dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .find(|e| {
                e.path()
                    .extension()
                    .map(|ext| ext.eq_ignore_ascii_case("exe"))
                    .unwrap_or(false)
            })
            .map(|e| e.path().to_path_buf());
        match exe {
            Some(p) => Ok(p),
            None => {
                fs::remove_dir_all(&tmp_dir).ok();
                anyhow::bail!("No .exe found inside the ZIP archive")
            }
        }
    } else {
        Ok(path.to_path_buf())
    }
}

fn seed_terminal_config(prefix: &Path) -> Result<()> {
    let config_dir = prefix.join("drive_c/ProgramData/MALightingTechnology/gma3_2.3.2/terminalapp/config");
    fs::create_dir_all(&config_dir)?;
    let config_file = config_dir.join("terminal.cfg");
    fs::write(
        &config_file,
        b"\x02\x00\x00\x00\x7f\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    )?;
    Ok(())
}

fn main() -> Result<()> {
    init_tracing();
    let args = Arguments::parse();

    let app_name = "gma3";
    let dirs = xdg::BaseDirectories::with_prefix(app_name)
        .context("Failed to get XDG base directories")?;
    let data_dir = dirs.get_data_home();
    let state_dir = dirs.get_state_home();
    let runtime_dir = dirs.get_runtime_directory()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|_| env::temp_dir());

    let paths = Paths {
        upper: data_dir,
        work: state_dir,
        wine_prefix: runtime_dir.join(format!("gma3-prefix-{}", std::process::id())),
    };

    paths.ensure_created().context("setting up directories")?;

    let uid = unsafe { getuid() };
    let gid = unsafe { getgid() };

    let program = if let Some(subcommand) = args.subcommand {
        ProgramToExecute::Other(subcommand)
    } else {
        ProgramToExecute::Gma3 { arguments: args.gma3_arguments }
    };

    // Try overlayfs mount in an unshared child process. If that fails, the parent
    // (still in the original namespaces) falls back to fuse-overlayfs.
    match try_privileged_mount(&paths,
        (uid.as_raw(), gid.as_raw()),
        &program,
        args.verbose,
    ) {
        Ok(()) => Ok(()),
        Err(MountFail) => {
            mount_run_unprivileged(&paths, &program, args.verbose)?;
            Ok(())
        }
    }
}

#[derive(Debug)]
enum ProgramToExecute {
    Gma3 { arguments: Vec<String> },
    Other(Program),
}

fn init_tracing() {
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::TRACE)
        .finish();
    let _ = tracing::subscriber::set_global_default(subscriber);
}

#[derive(Debug)]
struct MountFail;

fn try_privileged_mount(
    paths: &Paths,
    ids: (u32, u32),
    program: &ProgramToExecute,
    verbose: bool,
) -> Result<(), MountFail> {
    match unsafe { fork() } {
        Ok(ForkResult::Parent { child }) => {
            let status = nix::sys::wait::waitpid(child, None).map_err(|_| MountFail)?;
            match status {
                nix::sys::wait::WaitStatus::Exited(_, status) if status == MOUNT_FAIL_STATUS => {
                    Err(MountFail)
                }
                nix::sys::wait::WaitStatus::Exited(_, status) => {
                    std::process::exit(status);
                }
                _ => Ok(()),
            }
        }
        Ok(ForkResult::Child) => {
            unsafe {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            }
            let result = (|| -> Result<()> {
                unshare(CloneFlags::CLONE_NEWUSER | CloneFlags::CLONE_NEWNS)?;
                fs::write("/proc/self/setgroups", b"deny\n")?;
                fs::write("/proc/self/uid_map", format!("0 {} 1\n", ids.0))?;
                fs::write("/proc/self/gid_map", format!("0 {} 1\n", ids.1))?;
                mount_execute_privileged(paths, program, verbose)
            })();
            if let Err(err) = result {
                error!(error = ?err, "privileged mount failed");
                std::process::exit(MOUNT_FAIL_STATUS);
            }
            std::process::exit(0);
        }
        Err(err) => {
            error!(error = ?err, "fork failed");
            Err(MountFail)
        }
    }
}

fn mount_execute_privileged(
    paths: &Paths,
    program: &ProgramToExecute,
    verbose: bool,
) -> Result<()> {
    let options = make_mount_options(paths);
    mount(
        Some("overlay"),
        &paths.wine_prefix,
        Some("overlay"),
        MsFlags::empty(),
        Some(options.as_str()),
    )?;

    let result = execute(paths, program, verbose);

    let _ = umount(&paths.wine_prefix);
    let _ = fs::remove_dir(&paths.wine_prefix);

    result
}

fn mount_run_unprivileged(
    paths: &Paths,
    program: &ProgramToExecute,
    verbose: bool,
) -> Result<()> {
    // Ensure mount point exists and workdir is clean (kernel overlayfs may have
    // left a restricted work/ directory behind when the privileged child failed).
    let nested = paths.work.join("work");
    if nested.exists() {
        let _ = fs::set_permissions(&nested, fs::Permissions::from_mode(0o700));
        let _ = fs::remove_dir_all(&nested);
    }
    fs::create_dir_all(&paths.wine_prefix)?;

    let options = make_mount_options(paths);
    let _child = std::process::Command::new(FUSE_OVERLAYFS)
        .arg("-o")
        .arg(&options)
        .arg(&paths.wine_prefix)
        .spawn()?;

    std::thread::sleep(std::time::Duration::from_millis(500));

    let result = execute(paths, program, verbose);

    // Try to unmount
    let _ = std::process::Command::new("fusermount3")
        .args(["-u", "-z", &paths.wine_prefix.to_string_lossy()])
        .status();
    let _ = std::process::Command::new("fusermount")
        .args(["-u", "-z", &paths.wine_prefix.to_string_lossy()])
        .status();
    let _ = fs::remove_dir(&paths.wine_prefix);

    result
}

fn make_mount_options(paths: &Paths) -> String {
    format!(
        "lowerdir={},upperdir={},workdir={}",
        LOWER_DIR.display(),
        paths.upper.display(),
        paths.work.display()
    )
}

fn execute(paths: &Paths, program: &ProgramToExecute, verbose: bool) -> Result<()> {
    let user = env::var("USER").unwrap_or_else(|_| "user".to_string());

    eprintln!("[debug] warmup_prefix_directories...");
    warmup_prefix_directories(&paths.upper)?;
    eprintln!("[debug] warmup_prefix_registry...");
    warmup_prefix_registry(&paths.upper, &user)?;
    eprintln!("[debug] warmup_wintrust...");
    warmup_wintrust(&paths.wine_prefix)?;
    eprintln!("[debug] wineboot_update...");
    wineboot_update(&paths.wine_prefix, verbose)?;
    eprintln!("[debug] wineboot_update done");

    let gma3_exe = paths.wine_prefix
        .join("drive_c/Program Files/MALightingTechnology")
        .join("gma3_2.3.2/bin/app_system.exe");

    match program {
        ProgramToExecute::Gma3 { arguments: _ } => {
            if !gma3_exe.exists() {
                eprintln!("grandMA3 does not appear to be installed in the Wine prefix.");
                eprintln!("");
                eprintln!("To install, run:");
                eprintln!("  gma3 install /path/to/grandMA3_onPC_win_vX.Y.Z.W.exe");
                eprintln!("");
                eprintln!("Or for ZIP archives:");
                eprintln!("  gma3 install /path/to/grandMA3_onPC_win_vX.Y.Z.W.zip");
                eprintln!("");
                return Ok(());
            }
            let env = make_env(
                duct::cmd(WINE, &[gma3_exe.to_string_lossy().to_string()]),
                &paths.wine_prefix,
                verbose,
            );
            env.env("WINEDLLOVERRIDES", "wintrust=n,b;dxgi,d3d11=n")
                .env("WINEARCH", "win64")
                .env("LANG", "en_US.UTF-8")
                .env("LC_ALL", "en_US.UTF-8")
                .env("MESA_GL_VERSION_OVERRIDE", "4.2")
                .env("MESA_GLSL_VERSION_OVERRIDE", "420")
                .env("DXVK_LOG_LEVEL", "info")
                .run()?;
        }
        ProgramToExecute::Other(Program::Wine { arguments }) => {
            let env = make_env(duct::cmd(WINE, arguments), &paths.wine_prefix, verbose);
            env.run()?;
        }
        ProgramToExecute::Other(Program::Winetricks { arguments }) => {
            let env = make_env(duct::cmd(WINETRICKS, arguments), &paths.wine_prefix, verbose);
            env.run()?;
        }
        ProgramToExecute::Other(Program::Wineboot { arguments }) => {
            let mut args = vec!["wineboot".to_string()];
            args.extend(arguments.iter().cloned());
            let env = make_env(duct::cmd(WINE, &args), &paths.wine_prefix, verbose);
            env.run()?;
        }
        ProgramToExecute::Other(Program::Wineserver { arguments }) => {
            let env = make_env(duct::cmd(WINESERVER, arguments), &paths.wine_prefix, verbose);
            env.run()?;
        }
        ProgramToExecute::Other(Program::Probe) => {
            run_probe();
        }
        ProgramToExecute::Other(Program::Install { path }) => {
            let resolved = match verify_installer(path) {
                Ok(Some(version)) => {
                    println!("Verified installer: grandMA3 onPC v{}", version);
                    extract_installer(path)?
                }
                Ok(None) => {
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("Failed to verify installer: {}", e);
                    return Ok(());
                }
            };

            println!("Installing grandMA3 onPC into the Wine prefix...");

            // Install Visual C++ 2015-2022 redistributable first to avoid installer failure
            println!("Installing VC++ runtime via winetricks...");
            let winetricks_env = make_env(
                duct::cmd(WINETRICKS, &["-q", "vcrun2022"]),
                &paths.wine_prefix,
                verbose,
            );
            if let Err(e) = winetricks_env.run() {
                eprintln!("Warning: winetricks vcrun2019 failed: {}", e);
                eprintln!("Continuing anyway, the installer may still work...");
            }

            let env = make_env(
                duct::cmd(WINE, &["start", "/wait", "/unix", resolved.to_string_lossy().to_string().as_str(), "/S"]),
                &paths.wine_prefix,
                verbose,
            );
            env.run()?;

            // Seed terminal config
            if let Err(e) = seed_terminal_config(&paths.wine_prefix) {
                eprintln!("Warning: failed to seed terminal config: {}", e);
            }

            println!("Installation complete. You can now run `gma3` to launch grandMA3 onPC.");
        }
    }

    let _ = make_env(duct::cmd(WINESERVER, &["-w"]), &paths.wine_prefix, verbose).run();

    Ok(())
}

fn make_env(expression: duct::Expression, wine_prefix: &Path, verbose: bool) -> duct::Expression {
    let expression = expression
        .env("WINEPREFIX", wine_prefix.display().to_string())
        .env("WINEPATH", format!("{};{}", WINTRUST_STUB, DXVK))
        .env("WINEARCH", "win64")
        .env("WINEDLLOVERRIDES", "wintrust=n,b;mscoree=;mshtml=");
    if verbose {
        expression
    } else {
        expression.env("WINEDEBUG", "-all,fixme-all")
    }
}

fn warmup_prefix_directories(destination: &Path) -> Result<()> {
    for entry in walkdir::WalkDir::new(&*LOWER_DIR).into_iter().filter_map(|e| e.ok()) {
        if !entry.file_type().is_dir() {
            continue;
        }
        let relative_path = entry.path().strip_prefix(&*LOWER_DIR)?;
        let target_path = destination.join(relative_path);
        if let Err(err) = fs::create_dir_all(&target_path) {
            if err.kind() != std::io::ErrorKind::AlreadyExists {
                return Err(err.into());
            }
        }
    }
    Ok(())
}

fn warmup_wintrust(prefix: &Path) -> Result<()> {
    let stub_path = PathBuf::from(WINTRUST_STUB).join("wintrust.dll");
    eprintln!("[debug] warmup_wintrust stub_path={}", stub_path.display());
    if !stub_path.exists() {
        eprintln!("[debug] stub does not exist, skipping");
        return Ok(());
    }
    eprintln!("[debug] reading stub...");
    let stub_bytes = fs::read(&stub_path)?;
    eprintln!("[debug] stub size={}", stub_bytes.len());
    for subdir in ["system32", "syswow64"] {
        let dest_dir = prefix.join("drive_c/windows").join(subdir);
        eprintln!("[debug] creating dest_dir={}", dest_dir.display());
        fs::create_dir_all(&dest_dir)?;
        let dest = dest_dir.join("wintrust.dll");
        eprintln!("[debug] writing dest={}", dest.display());
        if let Err(e) = fs::write(&dest, &stub_bytes) {
            eprintln!("[debug] fs::write failed: kind={:?}, path={}", e.kind(), dest.display());
            return Err(e.into());
        }
        eprintln!("[debug] wrote dest OK");
    }
    Ok(())
}

fn warmup_prefix_registry(destination: &Path, user: &str) -> Result<()> {
    let important_files = vec!["system.reg", "user.reg", "userdef.reg", ".update-timestamp"];
    for file in important_files {
        let src_path = LOWER_DIR.join(file);
        if !src_path.exists() {
            continue;
        }
        let dst_path = destination.join(file);
        let content = fs::read_to_string(&src_path)?;
        let modified_content = content.replace("nixbld", user);
        fs::write(&dst_path, modified_content)?;

        let metadata = fs::metadata(&dst_path)?;
        let mut permissions = metadata.permissions();
        permissions.set_mode(permissions.mode() | 0o200);
        fs::set_permissions(&dst_path, permissions)?;
    }
    Ok(())
}

fn wineboot_update(wine_prefix: &Path, verbose: bool) -> Result<()> {
    let env = make_env(duct::cmd(WINE, &["wineboot", "--update"]), wine_prefix, verbose);
    env.run()?;
    Ok(())
}

fn run_probe() {
    println!("System probe:");
    println!("  OS: {}", std::env::consts::OS);
    println!("  Arch: {}", std::env::consts::ARCH);
    println!("  WINE: {}", WINE);
    println!("  WINESERVER: {}", WINESERVER);
    println!("  LOWER_DIR: {}", LOWER_DIR.display());
}
