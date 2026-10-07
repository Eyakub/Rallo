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

/// An item directory Rallo made: named by a UUID. The sweep and the audit
/// ignore everything else under `attachments/` (a `.DS_Store`, a stray folder).
pub(crate) fn is_item_dir(name: &std::ffi::OsStr) -> bool {
    name.to_str().is_some_and(|name| name.len() == 36 && Uuid::parse_str(name).is_ok())
}

/// A file Rallo wrote: `<uuid>.<ext>`, or `.<uuid>.tmp` mid-write.
pub(crate) fn is_image_file(name: &std::ffi::OsStr) -> bool {
    let Some(name) = name.to_str() else { return false };
    let uuid = |text: &str| text.len() == 36 && Uuid::parse_str(text).is_ok();
    match name.strip_prefix('.') {
        Some(temp) => temp.strip_suffix(".tmp").is_some_and(uuid),
        None => name
            .split_once('.')
            .is_some_and(|(id, extension)| uuid(id) && matches!(extension, "png" | "jpg" | "heic" | "gif" | "webp")),
    }
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
        // The entry's own type: a symlink to a directory is not followed.
        if !item_dir.file_type().is_ok_and(|kind| kind.is_dir()) || !is_item_dir(&item_dir.file_name()) {
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
            if !is_image_file(&entry.file_name()) {
                continue;
            }
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

/// Copies an image file into the store (import): temp file, sync, rename.
pub(crate) fn copy_in(
    data_dir: &Path,
    item_id: Uuid,
    image_id: Uuid,
    kind: ImageKind,
    source: &Path,
) -> CoreResult<PathBuf> {
    let dir = attachments_dir(data_dir).join(item_id.to_string());
    ensure_private_dir(&attachments_dir(data_dir))?;
    ensure_private_dir(&dir)?;
    let temp = dir.join(format!(".{image_id}.tmp"));
    let bytes = fs::read(source)?;
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temp)?;
    let path = dir.join(file_name(image_id, kind));
    // A leftover temp file would block a retry (`create_new`), so remove it
    // on any failure after creating it.
    let written = file.write_all(&bytes).and_then(|()| file.sync_all()).and_then(|()| fs::rename(&temp, &path));
    if let Err(error) = written {
        let _ = fs::remove_file(&temp);
        return Err(error.into());
    }
    Ok(path)
}

/// Copies every image file under `attachments/` to `to` (a backup's
/// `<name>.attachments`), keeping the `<item id>/<file>` layout. On APFS
/// `fs::copy` clones, so this costs almost no space. Returns the count.
pub(crate) fn copy_tree(data_dir: &Path, to: &Path) -> CoreResult<u64> {
    let Ok(item_dirs) = fs::read_dir(attachments_dir(data_dir)) else { return Ok(0) };
    let mut copied = 0;
    // The entry's own type: a symlinked directory is not followed.
    for item_dir in item_dirs.flatten().filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir())) {
        let target = to.join(item_dir.file_name());
        for entry in fs::read_dir(item_dir.path())?.flatten() {
            let name = entry.file_name();
            if name.to_string_lossy().starts_with('.') || !entry.file_type().is_ok_and(|kind| kind.is_file()) {
                continue; // a temp file mid-write, or not a plain file
            }
            ensure_private_dir(to)?;
            ensure_private_dir(&target)?;
            fs::copy(entry.path(), target.join(&name))?;
            fs::set_permissions(target.join(&name), std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
            copied += 1;
        }
    }
    Ok(copied)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn the_sweep_ignores_what_rallo_did_not_write() {
        let data = tempfile::tempdir().unwrap();
        let root = attachments_dir(data.path());
        let (item, image) = (Uuid::new_v4(), Uuid::new_v4());
        let item_dir = root.join(item.to_string());
        let stray_dir = root.join("Not A Uuid");
        fs::create_dir_all(&item_dir).unwrap();
        fs::create_dir_all(&stray_dir).unwrap();
        fs::write(root.join(".DS_Store"), b"x").unwrap();
        fs::write(item_dir.join(".DS_Store"), b"x").unwrap();
        fs::write(stray_dir.join(file_name(image, ImageKind::Png)), b"x").unwrap();
        let orphan = item_dir.join(file_name(image, ImageKind::Png));
        fs::write(&orphan, b"x").unwrap();
        let future = SystemTime::now() + Duration::from_secs(60);
        assert_eq!(remove_orphans(data.path(), &HashSet::new(), future).unwrap(), 1);
        assert!(!orphan.exists());
        assert!(root.join(".DS_Store").exists());
        assert!(item_dir.join(".DS_Store").exists());
        assert!(stray_dir.join(file_name(image, ImageKind::Png)).exists());
    }

    #[test]
    fn copy_in_removes_its_temp_file_when_the_rename_fails() {
        let data = tempfile::tempdir().unwrap();
        let source = data.path().join("source.png");
        fs::write(&source, b"\x89PNG\r\n\x1a\n").unwrap();
        let (item, image) = (Uuid::new_v4(), Uuid::new_v4());
        let dir = attachments_dir(data.path()).join(item.to_string());
        // A directory at the final path makes the rename fail.
        fs::create_dir_all(dir.join(file_name(image, ImageKind::Png))).unwrap();
        assert!(copy_in(data.path(), item, image, ImageKind::Png, &source).is_err());
        assert!(!dir.join(format!(".{image}.tmp")).exists());
    }
}
