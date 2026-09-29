use std::env;
use std::path::{Path, PathBuf};

use crate::shared::errors::{CoreError, CoreResult, ErrorCode};

/// Environment override for the data directory. Tests and development builds
/// use it to stay isolated from real user data.
pub const DATA_DIR_ENV: &str = "RALLO_DATA_DIR";

/// `~/Library/Application Support/Razlio/Rallo` — identical for CLI and app.
pub fn default_data_dir() -> CoreResult<PathBuf> {
    let home = env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .ok_or_else(|| CoreError::storage("HOME is not set; cannot locate the Rallo data directory"))?;
    Ok(PathBuf::from(home).join("Library/Application Support/Razlio/Rallo"))
}

/// Explicit path > `RALLO_DATA_DIR` > default. The result must be absolute so
/// every process derives the same lock and signal keys.
pub fn resolve_data_dir(explicit: Option<&Path>) -> CoreResult<PathBuf> {
    let chosen = match explicit {
        Some(path) => path.to_path_buf(),
        None => match env::var_os(DATA_DIR_ENV).filter(|value| !value.is_empty()) {
            Some(value) => PathBuf::from(value),
            None => default_data_dir()?,
        },
    };
    if !chosen.is_absolute() {
        return Err(CoreError::invalid(ErrorCode::InvalidInput, "the data directory must be an absolute path"));
    }
    Ok(chosen)
}
