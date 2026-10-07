//! Image files under `<data dir>/attachments/<item id>/` (0018): written to a
//! temp file, synced and renamed into place before their row is inserted.

use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use uuid::Uuid;

use super::format::ImageKind;
use crate::shared::errors::CoreResult;
use crate::shared::ids;
use crate::storage::database::ensure_private_dir;

pub const ATTACHMENTS_DIR: &str = "attachments";

pub fn attachments_dir(data_dir: &Path) -> PathBuf {
    data_dir.join(ATTACHMENTS_DIR)
}

pub fn file_name(id: Uuid, kind: ImageKind) -> String {
    format!("{id}.{}", kind.extension())
}

pub fn file_path(data_dir: &Path, item_id: Uuid, file_name: &str) -> PathBuf {
    attachments_dir(data_dir).join(item_id.to_string()).join(file_name)
}

pub(crate) struct NewImage<'a> {
    pub id: Uuid,
    pub kind: ImageKind,
    pub bytes: &'a [u8],
}

pub(crate) fn new_images<'a>(images: &'a [Vec<u8>], kinds: &[ImageKind]) -> Vec<NewImage<'a>> {
    images.iter().zip(kinds).map(|(bytes, kind)| NewImage { id: ids::new_id(), kind: *kind, bytes }).collect()
}

/// Files `write_all` put in place; `discard` removes them when the database
/// write that should follow did not happen.
#[must_use]
pub(crate) struct Written(Vec<PathBuf>);

impl Written {
    pub(crate) fn discard(self) {
        for path in &self.0 {
            let _ = fs::remove_file(path);
        }
        if let Some(dir) = self.0.first().and_then(|path| path.parent()) {
            let _ = fs::remove_dir(dir); // non-recursive: stays if other images are there
        }
    }
}

pub(crate) fn write_all(data_dir: &Path, item_id: Uuid, images: &[NewImage<'_>]) -> CoreResult<Written> {
    let mut written = Written(Vec::new());
    if images.is_empty() {
        return Ok(written);
    }
    let dir = attachments_dir(data_dir).join(item_id.to_string());
    let result: CoreResult<()> = (|| {
        ensure_private_dir(&attachments_dir(data_dir))?;
        ensure_private_dir(&dir)?;
        for image in images {
            let temp = dir.join(format!(".{}.tmp", image.id));
            let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp)?;
            file.write_all(image.bytes)?;
            file.sync_all()?;
            let path = dir.join(file_name(image.id, image.kind));
            fs::rename(&temp, &path)?;
            written.0.push(path);
        }
        Ok(())
    })();
    match result {
        Ok(()) => Ok(written),
        Err(error) => {
            written.discard();
            Err(error)
        }
    }
}

/// Removes files under `attachments/` that no row names (`known`) and that
/// were last modified before `older_than`, and item directories left empty.
/// Returns how many files it removed.
pub(crate) fn remove_orphans(data_dir: &Path, known: &HashSet<PathBuf>, older_than: SystemTime) -> CoreResult<u64> {
    let root = attachments_dir(data_dir);
    let Ok(item_dirs) = fs::read_dir(&root) else { return Ok(0) };
    let mut removed = 0;
    for item_dir in item_dirs.flatten() {
        let item_path = item_dir.path();
        if !item_path.is_dir() {
            continue;
        }
        // Best-effort: skip a directory we can't read; a later sweep retries.
        let Ok(entries) = fs::read_dir(&item_path) else { continue };
        // Taken before removing files, which would make it look fresh.
        let dir_stale = fs::metadata(&item_path)
            .and_then(|metadata| metadata.modified())
            .map(|modified| modified < older_than)
            .unwrap_or(false);
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(metadata) = fs::symlink_metadata(&path) else { continue };
            let stale = metadata.modified().map(|modified| modified < older_than).unwrap_or(false);
            if !known.contains(&path) && stale && fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
        if dir_stale {
            let _ = fs::remove_dir(&item_path); // only succeeds when empty
        }
    }
    Ok(removed)
}
