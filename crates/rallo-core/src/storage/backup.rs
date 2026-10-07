use std::fs;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::Connection;
use rusqlite::backup::Backup;
use serde::Serialize;
use uuid::Uuid;

use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::storage::database::Store;

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

/// Result of a successful `rallo backup`.
#[derive(Debug, Clone, Serialize)]
pub struct BackupSummary {
    pub path: PathBuf,
    pub bytes: u64,
    /// Image files copied to `<path>.attachments`.
    pub images: u64,
}

/// Default destination for `rallo backup` with no `--output`: `<data
/// dir>/backups/manual-<now_ms>.sqlite3`, the same millisecond-epoch naming
/// already used for the pre-migration and pre-import snapshots, so all three
/// kinds sort together and never collide within the same millisecond.
pub fn default_manual_backup_path(data_dir: &Path, now_ms: i64) -> PathBuf {
    data_dir.join("backups").join(format!("manual-{now_ms}.sqlite3"))
}

fn file_exists_error(path: &Path) -> CoreError {
    CoreError::conflict(
        ErrorCode::FileExists,
        format!("{} already exists; pass --force (overwrite: true) to replace it", path.display()),
    )
}

/// Writes a consistent snapshot of `conn` to `destination` (M4 `rallo
/// backup`): a temp file in `destination`'s own directory, explicitly
/// `fsync`'d, then renamed over the destination, mode `0600`. `conn` must have
/// no transaction of its own open -- the SQLite online backup API hangs
/// against a connection already holding a write transaction (found while
/// building 0004's pre-import snapshot), which is never the case for
/// `Store::conn()` between commands. Works against a live WAL database: the
/// backup API reads committed and checkpointed WAL content consistently even
/// while another connection (the running app) keeps writing.
pub fn backup_manual(conn: &Connection, destination: &Path, overwrite: bool) -> CoreResult<BackupSummary> {
    if !overwrite && destination.exists() {
        return Err(file_exists_error(destination));
    }
    let parent = match destination.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };
    super::database::ensure_private_dir(parent)?;
    let temp_path = parent.join(format!(".rallo-backup-{}.tmp", Uuid::new_v4()));
    fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp_path)?;
    {
        let mut target = Connection::open(&temp_path)?;
        Backup::new(conn, &mut target)?.run_to_completion(256, Duration::from_millis(5), None)?;
    }
    let file = fs::OpenOptions::new().write(true).open(&temp_path)?;
    file.sync_all()?;
    drop(file);
    if !overwrite && destination.exists() {
        let _ = fs::remove_file(&temp_path);
        return Err(file_exists_error(destination));
    }
    fs::rename(&temp_path, destination)?;
    let bytes = fs::metadata(destination)?.len();
    Ok(BackupSummary { path: destination.to_path_buf(), bytes, images: 0 })
}

impl Store {
    /// The database only, no `.attachments` folder: for the pre-update
    /// snapshot (0018 keeps pre-migration, pre-import and pre-update
    /// snapshots database-only).
    pub fn backup_database_to_file(&self, destination: &Path, overwrite: bool) -> CoreResult<BackupSummary> {
        backup_manual(self.conn(), destination, overwrite)
    }

    /// `rallo backup` (M4): see `backup_manual`. Never starts or signals the
    /// app; read-only against the store's own data.
    pub fn backup_to_file(&self, destination: &Path, overwrite: bool) -> CoreResult<BackupSummary> {
        let mut summary = self.backup_database_to_file(destination, overwrite)?;
        let images_to = PathBuf::from(format!("{}.attachments", destination.display()));
        if overwrite && images_to.exists() {
            fs::remove_dir_all(&images_to)?;
        }
        summary.images = crate::images::files::copy_tree(self.data_dir(), &images_to)?;
        Ok(summary)
    }
}
