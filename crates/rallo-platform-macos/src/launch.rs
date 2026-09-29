use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Development override pointing at a built `Rallo.app`.
pub const APP_PATH_ENV: &str = "RALLO_APP_PATH";
pub const BUNDLE_IDENTIFIER: &str = "com.razlio.rallo";

#[derive(Debug, thiserror::Error)]
pub enum LaunchError {
    #[error("the Rallo app could not be located; run the CLI from an installed Rallo.app or set {APP_PATH_ENV}")]
    AppNotFound,
    #[error("macOS refused to launch the Rallo app ({0})")]
    LaunchFailed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchMode {
    /// Initialise scheduling; never shows onboarding or steals focus.
    Background,
    /// The user explicitly asked to see the pet.
    Show,
}

impl LaunchMode {
    fn argument(self) -> &'static str {
        match self {
            Self::Background => "--background",
            Self::Show => "--show",
        }
    }
}

/// Finds the app bundle that contains this CLI (`Rallo.app/Contents/Helpers/rallo`),
/// following the user's PATH symlink. Never asks a shell to resolve anything.
pub fn locate_app() -> Result<PathBuf, LaunchError> {
    if let Some(path) = env::var_os(APP_PATH_ENV).filter(|value| !value.is_empty()) {
        let path = PathBuf::from(path);
        return is_app_bundle(&path).then_some(path).ok_or(LaunchError::AppNotFound);
    }
    let exe = env::current_exe().and_then(|exe| exe.canonicalize()).map_err(|_| LaunchError::AppNotFound)?;
    exe.ancestors()
        .find(|ancestor| ancestor.extension().is_some_and(|ext| ext == "app"))
        .filter(|app| is_app_bundle(app))
        .map(Path::to_path_buf)
        .ok_or(LaunchError::AppNotFound)
}

fn is_app_bundle(path: &Path) -> bool {
    path.join("Contents/Info.plist").is_file()
}

/// Asks LaunchServices (via `open -g`, which does not activate the app) to
/// start Rallo, and waits only until the OS has accepted the request — not for
/// the app to finish starting. The launcher's stdio is detached so an agent's
/// captured pipes close as soon as the CLI exits.
pub fn launch(app: &Path, mode: LaunchMode, data_dir: &Path) -> Result<(), LaunchError> {
    let status = Command::new("/usr/bin/open")
        .arg("-g")
        .arg("-a")
        .arg(app)
        .arg("--args")
        .arg(mode.argument())
        .arg("--data-dir")
        .arg(data_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|error| LaunchError::LaunchFailed(error.to_string()))?;
    if status.success() { Ok(()) } else { Err(LaunchError::LaunchFailed(status.to_string())) }
}
