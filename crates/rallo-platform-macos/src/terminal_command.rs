//! Puts the bundled CLI on the user's PATH as a symlink (spec §10, "Terminal
//! command setup"). Mirrors `apps/macos/Rallo/Setup/TerminalCommand.swift`:
//! only `~/.local/bin` or `~/bin` are used, never another tool's directory,
//! and an existing `rallo` that is not Rallo's own link is never replaced.
//! Everything is scoped to an explicit `home`/PATH list rather than the real
//! environment so tests can point it at a temporary directory.

use std::env;
use std::fs;
use std::io::Read;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

pub const NAME: &str = "rallo";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    /// `link` already points at this app's CLI.
    Enabled { link: PathBuf, on_path: bool },
    /// Nothing there yet; `on_path` says whether `directory` is on PATH.
    Available { directory: PathBuf, on_path: bool },
    /// Rallo's link from a moved or deleted copy of the app.
    Repairable { link: PathBuf, old_target: PathBuf, on_path: bool },
    /// Some other `rallo` exists; leave it alone.
    Conflict { existing: PathBuf },
    /// Running from somewhere other than an installed Applications copy.
    NotInstalled,
}

#[derive(Debug, thiserror::Error)]
pub enum TerminalCommandError {
    #[error("the command-line tool is missing or not executable at {}", .0.display())]
    CliMissing(PathBuf),
    #[error("Rallo won't replace an existing command")]
    NotAllowed,
    #[error("could not resolve the running executable's location")]
    ExeNotFound,
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

/// The CLI inside an app bundle.
pub fn cli_path(app: &Path) -> PathBuf {
    app.join("Contents/Helpers/rallo")
}

/// The `Rallo.app` bundle containing the currently running executable,
/// resolved via its real (symlink-followed) path on disk -- never by asking
/// a shell or trusting `argv[0]`.
pub fn locate_running_app() -> Result<PathBuf, TerminalCommandError> {
    let exe = env::current_exe().and_then(|exe| exe.canonicalize()).map_err(|_| TerminalCommandError::ExeNotFound)?;
    exe.ancestors()
        .find(|ancestor| ancestor.extension().is_some_and(|ext| ext == "app"))
        .map(Path::to_path_buf)
        .ok_or(TerminalCommandError::ExeNotFound)
}

/// `$HOME`, exactly as the environment sets it (never the passwd database),
/// so a temporary directory can stand in for it under test.
pub fn home_dir() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from).filter(|home| !home.as_os_str().is_empty())
}

/// An installed copy lives directly inside `/Applications` or `~/Applications`.
pub fn is_installed(app: &Path, home: &Path) -> bool {
    match app.parent() {
        Some(parent) => parent == Path::new("/Applications") || parent == home.join("Applications"),
        None => false,
    }
}

/// The user's shell, as the environment names it.
pub fn user_shell() -> PathBuf {
    env::var_os("SHELL").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/bin/zsh"))
}

/// The startup file a login shell reads even when it isn't interactive.
pub fn login_profile(shell: &Path) -> &'static str {
    match shell.file_name().and_then(|name| name.to_str()) {
        Some("bash") => "~/.bash_profile",
        Some("zsh") => "~/.zprofile",
        _ => "~/.profile",
    }
}

/// PATH as `shell -lc` sets it from a fresh environment: what tools that run commands without an
/// interactive terminal see (some agents, IDE tasks). An interactive
/// terminal also reads `~/.zshrc`, so a directory added only there works in
/// Terminal but not for them. `None` if the shell doesn't answer in time.
pub fn noninteractive_login_path(shell: &Path, timeout: Duration) -> Option<Vec<PathBuf>> {
    // Start from what launchd gives a freshly launched app, not this
    // process's PATH, which a terminal has usually already extended.
    let mut command = Command::new(shell);
    command.env_clear().env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"] {
        if let Some(value) = env::var_os(key) {
            command.env(key, value);
        }
    }
    let mut child = command
        .args(["-lc", r#"printf '%s' "$PATH""#])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut output = String::new();
    child.stdout.take()?.read_to_string(&mut output).ok()?;
    Some(env::split_paths(output.trim()).collect())
}

/// Preferred link directories, in order.
pub fn candidates(home: &Path) -> [PathBuf; 2] {
    [home.join(".local/bin"), home.join("bin")]
}

pub fn inspect(app: &Path, home: &Path, path_dirs: &[PathBuf]) -> State {
    if !is_installed(app, home) {
        return State::NotInstalled;
    }
    let target = cli_path(app);

    // A `rallo` earlier on PATH than ours would shadow any link we add.
    for directory in path_dirs {
        let existing = directory.join(NAME);
        if existing.symlink_metadata().is_err() {
            continue;
        }
        if let Ok(destination) = fs::read_link(&existing)
            && is_rallo_cli(&destination)
        {
            break;
        }
        return State::Conflict { existing };
    }

    let candidates = candidates(home);
    let directory = candidates.iter().find(|candidate| path_dirs.contains(candidate)).unwrap_or(&candidates[0]);
    let link = directory.join(NAME);
    let on_path = path_dirs.contains(directory);
    if let Ok(destination) = fs::read_link(&link) {
        return if destination == target {
            State::Enabled { link, on_path }
        } else if is_rallo_cli(&destination) {
            State::Repairable { link, old_target: destination, on_path }
        } else {
            State::Conflict { existing: link }
        };
    }
    if link.exists() {
        return State::Conflict { existing: link };
    }
    State::Available { directory: directory.clone(), on_path }
}

/// Creates (or, for `Repairable`, replaces Rallo's own) link and checks that
/// it resolves to an executable CLI.
pub fn enable(state: &State, app: &Path) -> Result<PathBuf, TerminalCommandError> {
    let target = cli_path(app);
    if !is_executable(&target) {
        return Err(TerminalCommandError::CliMissing(target));
    }
    let link = match state {
        State::Available { directory, .. } => {
            fs::create_dir_all(directory)?;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o755))?;
            directory.join(NAME)
        }
        State::Repairable { link, .. } => {
            fs::remove_file(link)?;
            link.clone()
        }
        State::Enabled { link, .. } => return Ok(link.clone()),
        State::Conflict { .. } | State::NotInstalled => return Err(TerminalCommandError::NotAllowed),
    };
    symlink(&target, &link)?;
    if !is_executable(&link) {
        return Err(TerminalCommandError::CliMissing(link));
    }
    Ok(link)
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path).map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

fn is_rallo_cli(path: &Path) -> bool {
    path.to_string_lossy().ends_with("/Rallo.app/Contents/Helpers/rallo")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_cli(app: &Path) -> PathBuf {
        let helpers = app.join("Contents/Helpers");
        fs::create_dir_all(&helpers).unwrap();
        let cli = helpers.join("rallo");
        fs::write(&cli, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&cli, fs::Permissions::from_mode(0o755)).unwrap();
        cli
    }

    fn scratch() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("Home With Spaces");
        let app = home.join("Applications/Rallo.app");
        make_cli(&app);
        (root, home, app)
    }

    #[test]
    fn fresh_install_links_into_local_bin_on_path() {
        let (_root, home, app) = scratch();
        let local_bin = home.join(".local/bin");
        let path_dirs = vec![local_bin.clone(), PathBuf::from("/usr/bin")];
        let state = inspect(&app, &home, &path_dirs);
        assert_eq!(state, State::Available { directory: local_bin.clone(), on_path: true });
        let link = enable(&state, &app).unwrap();
        assert_eq!(fs::read_link(&link).unwrap(), cli_path(&app));
        assert_eq!(inspect(&app, &home, &path_dirs), State::Enabled { link, on_path: true });
    }

    #[test]
    fn local_bin_off_path_is_still_proposed_and_reported() {
        let (_root, home, app) = scratch();
        let local_bin = home.join(".local/bin");
        let state = inspect(&app, &home, &[PathBuf::from("/usr/bin")]);
        assert_eq!(state, State::Available { directory: local_bin, on_path: false });
    }

    #[test]
    fn moved_app_is_repairable() {
        let (_root, home, app) = scratch();
        let local_bin = home.join(".local/bin");
        fs::create_dir_all(&local_bin).unwrap();
        let old = PathBuf::from("/Volumes/Rallo/Rallo.app/Contents/Helpers/rallo");
        symlink(&old, local_bin.join(NAME)).unwrap();
        let path_dirs = vec![local_bin.clone()];
        let state = inspect(&app, &home, &path_dirs);
        assert_eq!(state, State::Repairable { link: local_bin.join(NAME), old_target: old, on_path: true });
        let link = enable(&state, &app).unwrap();
        assert_eq!(inspect(&app, &home, &path_dirs), State::Enabled { link, on_path: true });
    }

    #[test]
    fn another_rallo_is_never_replaced() {
        let (_root, home, app) = scratch();
        let local_bin = home.join(".local/bin");
        fs::create_dir_all(&local_bin).unwrap();
        let other = local_bin.join(NAME);
        fs::write(&other, "someone else's tool").unwrap();
        let path_dirs = vec![local_bin.clone()];
        let state = inspect(&app, &home, &path_dirs);
        assert_eq!(state, State::Conflict { existing: other.clone() });
        assert!(enable(&state, &app).is_err());
        assert_eq!(fs::read_to_string(&other).unwrap(), "someone else's tool");
    }

    #[test]
    fn an_earlier_rallo_on_path_is_a_conflict() {
        let (root, home, app) = scratch();
        let earlier = root.path().join("tools");
        fs::create_dir_all(&earlier).unwrap();
        fs::write(earlier.join(NAME), "").unwrap();
        let local_bin = home.join(".local/bin");
        let path_dirs = vec![earlier.clone(), local_bin];
        assert_eq!(inspect(&app, &home, &path_dirs), State::Conflict { existing: earlier.join(NAME) });
    }

    #[test]
    fn app_outside_applications_is_not_installed() {
        let (root, home, _app) = scratch();
        let app = root.path().join("Downloads/Rallo.app");
        make_cli(&app);
        assert_eq!(inspect(&app, &home, &[]), State::NotInstalled);
    }
}
