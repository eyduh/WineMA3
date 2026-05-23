use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nix::mount::{mount, umount, MsFlags};
use nix::sched::{unshare, CloneFlags};
use nix::unistd::{fork, getgid, getuid, ForkResult};
use std::env;
use std::fs;
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
pub(crate) static LOWER_DIR: LazyLock<PathBuf> = LazyLock::new(|| PathBuf::from(env!("LOWER_DIR")));

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

    let unshare_result = unshare(CloneFlags::CLONE_NEWUSER | CloneFlags::CLONE_NEWNS | CloneFlags::CLONE_NEWPID);

    let program = if let Some(subcommand) = args.subcommand {
        ProgramToExecute::Other(subcommand)
    } else {
        ProgramToExecute::Gma3 { arguments: args.gma3_arguments }
    };

    match unshare_result {
        Ok(()) => mount_run_privileged(&paths, (uid.as_raw(), gid.as_raw()), &program, args.verbose),
        Err(err) => {
            error!(errno = ?err, "unshare failed, falling back to fuse-overlayfs");
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

fn mount_run_privileged(
    paths: &Paths,
    ids: (u32, u32),
    program: &ProgramToExecute,
    verbose: bool,
) -> Result<()> {
    fs::write("/proc/self/setgroups", b"deny\n")?;
    fs::write("/proc/self/uid_map", format!("0 {} 1\n", ids.0))?;
    fs::write("/proc/self/gid_map", format!("0 {} 1\n", ids.1))?;

    match unsafe { fork() } {
        Ok(ForkResult::Parent { child }) => {
            let status = nix::sys::wait::waitpid(child, None)?;
            match status {
                nix::sys::wait::WaitStatus::Exited(_, status) if status == MOUNT_FAIL_STATUS => {
                    mount_run_unprivileged(paths, program, verbose)?;
                }
                nix::sys::wait::WaitStatus::Exited(_, status) => {
                    std::process::exit(status);
                }
                _ => {}
            }
        }
        Ok(ForkResult::Child) => {
            unsafe {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            }
            let result = mount_execute_privileged(paths, program, verbose);
            if let Err(err) = result {
                error!(error = ?err, "privileged mount failed");
                std::process::exit(MOUNT_FAIL_STATUS);
            }
            std::process::exit(0);
        }
        Err(err) => {
            error!(error = ?err, "fork failed");
            mount_run_unprivileged(paths, program, verbose)?;
        }
    }
    Ok(())
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
    let options = make_mount_options(paths);
    let child = std::process::Command::new(FUSE_OVERLAYFS)
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

    warmup_prefix_directories(&paths.upper)?;
    warmup_prefix_registry(&paths.upper, &user)?;
    wineboot_update(&paths.wine_prefix, verbose)?;

    let gma3_exe = paths.wine_prefix
        .join("drive_c/Program Files/MALightingTechnology")
        .join("gma3_2.3.2/bin/app_system.exe");

    match program {
        ProgramToExecute::Gma3 { arguments: _ } => {
            if !gma3_exe.exists() {
                eprintln!("grandMA3 does not appear to be installed in the Wine prefix.");
                eprintln!("");
                eprintln!("To install, run:");
                eprintln!("  gma3 wine /path/to/grandMA3_onPC_win_vX.Y.Z.W.exe /S");
                eprintln!("");
                eprintln!("Or prefetch the installer into Nix and rebuild the package.");
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
    }

    let _ = make_env(duct::cmd(WINESERVER, &["-w"]), &paths.wine_prefix, verbose).run();

    Ok(())
}

fn make_env(expression: duct::Expression, wine_prefix: &Path, verbose: bool) -> duct::Expression {
    let expression = expression
        .env("WINEPREFIX", wine_prefix.display().to_string())
        .env("WINEPATH", DXVK);
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
