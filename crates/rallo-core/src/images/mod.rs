//! Images on notes (0018).

// Tasks 3-7 use the write, check and sweep helpers that nothing calls yet.
#![allow(dead_code)]

pub mod files;
pub mod format;
pub(crate) mod repository;

use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde::Serialize;
use uuid::Uuid;

pub use files::ATTACHMENTS_DIR;
pub use format::{ImageKind, MAX_IMAGE_BYTES, MAX_IMAGES_PER_NOTE};

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
