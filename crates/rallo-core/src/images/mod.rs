//! Images on notes (0018).

pub mod files;
pub mod format;
pub(crate) mod repository;
mod service;

use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde::Serialize;
use uuid::Uuid;

pub use files::ATTACHMENTS_DIR;
pub use format::{ImageKind, MAX_IMAGE_BYTES, MAX_IMAGES_PER_NOTE};
pub use service::{DELETED_IMAGE_RETENTION_MS, SweepSummary};

use crate::shared::errors::CoreResult;

/// One image as callers see it: `path` is absolute, so agents can open it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ImageView {
    pub id: Uuid,
    pub path: PathBuf,
    #[serde(rename = "type")]
    pub mime_type: String,
    #[serde(rename = "bytes")]
    pub byte_size: i64,
}

/// The data directory a connection's main database lives in.
fn data_dir_of(conn: &Connection) -> PathBuf {
    conn.path().and_then(|path| Path::new(path).parent()).map(Path::to_path_buf).unwrap_or_default()
}

pub(crate) fn views(conn: &Connection, item_id: Uuid) -> CoreResult<Vec<ImageView>> {
    let rows = repository::for_item(conn, item_id)?;
    if rows.is_empty() {
        return Ok(Vec::new());
    }
    let data_dir = data_dir_of(conn);
    Ok(rows
        .into_iter()
        .map(|row| ImageView {
            id: row.id,
            path: files::file_path(&data_dir, item_id, &row.file_name),
            mime_type: row.mime_type,
            byte_size: row.byte_size,
        })
        .collect())
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ImageAudit {
    pub count: u64,
    pub bytes: u64,
    pub orphan_files: u64,
    /// Paths of images whose file is gone.
    pub missing: Vec<String>,
}

/// What `rallo doctor` reports (0018). Read-only; `conn` may be a read-only
/// connection to a database older than schema 5, which has no images.
pub fn audit(conn: &Connection, data_dir: &Path) -> CoreResult<ImageAudit> {
    let has_table: bool = conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'attachments')",
        [],
        |row| row.get(0),
    )?;
    let rows = if has_table { repository::all(conn)? } else { Vec::new() };
    let known: std::collections::HashSet<PathBuf> =
        rows.iter().map(|row| files::file_path(data_dir, row.item_id, &row.file_name)).collect();
    let mut audit = ImageAudit {
        count: rows.len() as u64,
        bytes: rows.iter().map(|row| row.byte_size as u64).sum(),
        ..ImageAudit::default()
    };
    audit.missing = rows
        .iter()
        .map(|row| files::file_path(data_dir, row.item_id, &row.file_name))
        .filter(|path| !path.exists())
        .map(|path| path.display().to_string())
        .collect();
    if let Ok(item_dirs) = std::fs::read_dir(files::attachments_dir(data_dir)) {
        let item_dirs = item_dirs.flatten().filter(|entry| {
            entry.file_type().is_ok_and(|kind| kind.is_dir()) && files::is_item_dir(&entry.file_name())
        });
        for item_dir in item_dirs {
            // Best-effort like the sweep: an unreadable directory is skipped.
            let Ok(entries) = std::fs::read_dir(item_dir.path()) else { continue };
            for entry in entries.flatten() {
                if files::is_image_file(&entry.file_name()) && !known.contains(&entry.path()) {
                    audit.orphan_files += 1;
                }
            }
        }
    }
    Ok(audit)
}
