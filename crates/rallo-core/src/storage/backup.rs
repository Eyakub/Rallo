use std::fs;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::Connection;
use rusqlite::backup::Backup;

use crate::shared::errors::CoreResult;

/// Writes a consistent snapshot of `conn` (including uncheckpointed WAL
/// content) using the SQLite online backup API.
pub fn snapshot(conn: &Connection, destination: &Path) -> CoreResult<PathBuf> {
    if let Some(parent) = destination.parent() {
        super::database::ensure_private_dir(parent)?;
    }
    fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(destination)?;
    let mut target = Connection::open(destination)?;
    Backup::new(conn, &mut target)?.run_to_completion(256, Duration::from_millis(5), None)?;
    Ok(destination.to_path_buf())
}
