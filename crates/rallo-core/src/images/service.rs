//! Adding and removing a note's images, and the sweep (0018).

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use serde::Serialize;
use uuid::Uuid;

use super::{files, format, repository};
use crate::items::model::{MutationOptions, MutationOutcome};
use crate::items::service::{deleted_precondition, mutate_by_selector};
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::storage::database::{Store, bump_revision};

pub const DELETED_IMAGE_RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;
// ponytail: an orphan must be an hour old before the sweep removes it, so the
// app never sweeps a file the CLI is about to commit a row for.
const ORPHAN_GRACE: Duration = Duration::from_secs(60 * 60);

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SweepSummary {
    pub expired_images: u64,
    pub orphan_files: u64,
}

#[derive(Serialize)]
struct AttachInputs<'a> {
    command: &'static str,
    selector: &'a str,
    images: Vec<String>,
    if_revision: Option<i64>,
}

#[derive(Serialize)]
struct DetachInputs<'a> {
    command: &'static str,
    selector: &'a str,
    image_id: &'a str,
    if_revision: Option<i64>,
}

fn too_many() -> CoreError {
    CoreError::invalid(ErrorCode::TooManyImages, format!("a note can hold {} images", format::MAX_IMAGES_PER_NOTE))
}

impl Store {
    /// `rallo attach ID PATH…`: writes the files first, then adds their rows
    /// in the usual mutation transaction; files are removed if it doesn't
    /// commit.
    pub fn attach_images(
        &mut self,
        selector: &str,
        images: &[Vec<u8>],
        opts: &MutationOptions,
    ) -> CoreResult<MutationOutcome> {
        if images.is_empty() {
            return Err(CoreError::invalid(ErrorCode::InvalidInput, "no images to attach"));
        }
        let kinds = format::check_batch(images, 0)?;
        let target = crate::items::repository::resolve(self.conn(), selector)?.id;
        let new_images = files::new_images(images, &kinds);
        let written = files::write_all(self.data_dir(), target, &new_images)?;
        let inputs = AttachInputs {
            command: "attach_images",
            selector,
            images: format::digests(images),
            if_revision: opts.if_revision,
        };
        let adding = &new_images;
        let result = mutate_by_selector(
            self,
            "attach_images",
            selector,
            opts,
            &inputs,
            |tx, item| {
                deleted_precondition(tx, item)?;
                if item.id != target {
                    return Err(CoreError::conflict(ErrorCode::RevisionConflict, "the note changed; try again"));
                }
                if repository::count(tx, item.id)? + adding.len() > format::MAX_IMAGES_PER_NOTE {
                    return Err(too_many());
                }
                Ok(())
            },
            |_tx, _item| Ok(false),
            |tx, item, now| {
                repository::insert(tx, item.id, adding, now)?;
                crate::items::repository::touch(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        );
        if !matches!(&result, Ok(outcome) if !outcome.replayed) {
            written.discard();
        }
        result
    }

    /// `rallo detach ID IMAGE_ID`: removes the row, then the file.
    pub fn detach_image(
        &mut self,
        selector: &str,
        image_id: &str,
        opts: &MutationOptions,
    ) -> CoreResult<MutationOutcome> {
        let image = Uuid::parse_str(image_id)
            .map_err(|_| CoreError::invalid(ErrorCode::InvalidId, format!("\"{image_id}\" isn't an image ID")))?;
        let inputs = DetachInputs { command: "detach_image", selector, image_id, if_revision: opts.if_revision };
        let data_dir = self.data_dir().to_path_buf();
        let mut removed: Option<PathBuf> = None;
        let result = mutate_by_selector(
            self,
            "detach_image",
            selector,
            opts,
            &inputs,
            |tx, item| {
                deleted_precondition(tx, item)?;
                let rows = repository::for_item(tx, item.id)?;
                if !rows.iter().any(|row| row.id == image) {
                    return Err(CoreError::not_found(
                        ErrorCode::ImageNotFound,
                        format!("the note has no image {image_id}"),
                    ));
                }
                if rows.len() == 1 && item.text.trim().is_empty() {
                    return Err(CoreError::invalid(
                        ErrorCode::TextEmpty,
                        "a note needs text or an image; delete the note instead",
                    ));
                }
                Ok(())
            },
            |_tx, _item| Ok(false),
            |tx, item, now| {
                if let Some(row) = repository::delete_one(tx, item.id, image)? {
                    removed = Some(files::file_path(&data_dir, item.id, &row.file_name));
                }
                crate::items::repository::touch(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        );
        if let (Ok(outcome), Some(path)) = (&result, removed)
            && !outcome.replayed
        {
            let _ = fs::remove_file(path);
        }
        result
    }

    /// The app runs this when it opens the store and once a day (0018):
    /// images of notes deleted 30+ days ago go, then hour-old orphan files.
    pub fn sweep_images(&mut self) -> CoreResult<SweepSummary> {
        let now = self.now_ms();
        let data_dir = self.data_dir().to_path_buf();
        let tx = self.write_tx()?;
        let expired = repository::of_items_deleted_before(&tx, now - DELETED_IMAGE_RETENTION_MS)?;
        if !expired.is_empty() {
            repository::delete_ids(&tx, &expired.iter().map(|row| row.id).collect::<Vec<_>>())?;
            bump_revision(&tx)?;
        }
        let known: HashSet<PathBuf> =
            repository::all(&tx)?.iter().map(|row| files::file_path(&data_dir, row.item_id, &row.file_name)).collect();
        tx.commit()?;
        for row in &expired {
            let _ = fs::remove_file(files::file_path(&data_dir, row.item_id, &row.file_name));
        }
        let orphan_files = files::remove_orphans(&data_dir, &known, SystemTime::now() - ORPHAN_GRACE)?;
        Ok(SweepSummary { expired_images: expired.len() as u64, orphan_files })
    }
}
