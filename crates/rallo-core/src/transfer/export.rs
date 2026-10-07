//! `rallo export` (build plan §5, §10; decision 0004): a lossless versioned
//! JSON backup, or a spreadsheet-friendly CSV. Both read the entire item set
//! (live and deleted) from one consistent read-transaction snapshot, so a
//! concurrent writer cannot produce a torn export.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use serde::Serialize;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use super::formula_guard::apply_formula_guard;
use crate::images::repository as images_repository;
use crate::items::model::Item;
use crate::items::repository as items_repository;
use crate::reminders::model::Reminder;
use crate::reminders::repository as reminders_repository;
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::storage::database::{Store, ensure_private_dir};
use crate::storage::migrations::SCHEMA_VERSION;

/// Tag identifying the JSON backup document (0004), used both to write it and
/// to detect it on import.
pub const EXPORT_FORMAT_TAG: &str = "rallo.export";
/// The newest version of the JSON backup document shape this build reads,
/// independent of the database schema version recorded alongside it.
/// Version 2 is the zip export's document (0018), with each note's `images`.
pub const EXPORT_VERSION: u32 = 2;
/// What plain JSON exports write: they carry no images.
const PLAIN_JSON_VERSION: u32 = 1;
/// The zip export's document and image folder (0018).
pub const ARCHIVE_DOCUMENT: &str = "rallo-export.json";
pub const ARCHIVE_IMAGES_DIR: &str = "images";

const CSV_HEADER: [&str; 7] = ["id", "text", "status", "created_at", "completed_at", "reminder_at", "reminder_state"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ExportFormat {
    Json,
    Csv,
}

/// Result of a successful `export_to_file`.
#[derive(Debug, Clone, Serialize)]
pub struct ExportSummary {
    /// Notes written: every item for JSON, nondeleted items for CSV.
    pub items: u64,
    pub path: PathBuf,
    pub warnings: Vec<String>,
}

#[derive(Serialize)]
struct ExportDocument {
    format: &'static str,
    version: u32,
    exported_at: String,
    core_version: &'static str,
    schema_version: u32,
    items: Vec<ExportItem>,
}

#[derive(Serialize)]
struct ExportItem {
    id: Uuid,
    text: String,
    status: &'static str,
    created_at_ms: i64,
    updated_at_ms: i64,
    completed_at_ms: Option<i64>,
    deleted_at_ms: Option<i64>,
    reminder: Option<ExportReminder>,
    #[serde(skip_serializing_if = "Option::is_none")]
    images: Option<Vec<ExportImage>>,
}

#[derive(Serialize)]
struct ExportImage {
    id: Uuid,
    /// Relative to the archive root: `images/<item id>/<image id>.<ext>`.
    file: String,
    #[serde(rename = "type")]
    mime_type: String,
    bytes: i64,
    created_at_ms: i64,
}

#[derive(Serialize)]
struct ExportReminder {
    id: Uuid,
    deadline_ms: i64,
    time_input: String,
    input_kind: &'static str,
    input_offset_seconds: Option<i32>,
    state: &'static str,
    acknowledged_at_ms: Option<i64>,
    created_at_ms: i64,
    updated_at_ms: i64,
}

pub(super) fn rfc3339_utc_ms(ms: i64) -> String {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(ms) * 1_000_000)
        .expect("timestamps stay within RFC 3339's representable range")
        .format(&Rfc3339)
        .expect("RFC 3339 formatting cannot fail for a valid OffsetDateTime")
}

/// One consistent read-transaction snapshot of every item and its reminder
/// (if any), oldest first. `Connection::unchecked_transaction` works from
/// `&Store` (no `&mut` needed for a read): in WAL mode the snapshot is fixed
/// as of the first statement and held until the transaction ends, so a
/// concurrent writer's commits are invisible to it (0004).
fn snapshot(store: &Store) -> CoreResult<Vec<(Item, Option<Reminder>)>> {
    let tx = store.conn().unchecked_transaction()?;
    let items = items_repository::all_items_for_export(&tx)?;
    let mut rows = Vec::with_capacity(items.len());
    for item in items {
        let reminder = reminders_repository::fetch_by_item(&tx, item.id)?;
        rows.push((item, reminder));
    }
    tx.rollback()?; // read-only: nothing to persist.
    Ok(rows)
}

fn export_item(item: &Item, reminder: Option<&Reminder>, images: Option<Vec<ExportImage>>) -> ExportItem {
    ExportItem {
        id: item.id,
        text: item.text.clone(),
        status: item.status.as_str(),
        created_at_ms: item.created_at_ms,
        updated_at_ms: item.updated_at_ms,
        completed_at_ms: item.completed_at_ms,
        deleted_at_ms: item.deleted_at_ms,
        reminder: reminder.map(|reminder| ExportReminder {
            id: reminder.id,
            deadline_ms: reminder.deadline_ms,
            time_input: reminder.time_input.clone(),
            input_kind: reminder.input_kind.as_str(),
            input_offset_seconds: reminder.input_offset_seconds,
            state: reminder.state().as_str(),
            acknowledged_at_ms: reminder.acknowledged_at_ms,
            created_at_ms: reminder.created_at_ms,
            updated_at_ms: reminder.updated_at_ms,
        }),
        images,
    }
}

fn encode_json(store: &Store, rows: &[(Item, Option<Reminder>)]) -> CoreResult<Vec<u8>> {
    let document = ExportDocument {
        format: EXPORT_FORMAT_TAG,
        version: PLAIN_JSON_VERSION,
        exported_at: rfc3339_utc_ms(store.now_ms()),
        core_version: crate::CORE_VERSION,
        schema_version: SCHEMA_VERSION,
        // Only image-only notes have empty text; plain JSON can't carry them.
        items: rows
            .iter()
            .filter(|(item, _)| !item.text.is_empty())
            .map(|(item, reminder)| export_item(item, reminder.as_ref(), None))
            .collect(),
    };
    Ok(serde_json::to_vec_pretty(&document).expect("ExportDocument serializes"))
}

/// RFC 4180 with a UTF-8 BOM (Excel encoding detection) and CRLF records
/// (0004). Excludes deleted items; the formula-injection guard is applied to
/// `text` only.
fn encode_csv(rows: &[(Item, Option<Reminder>)]) -> CoreResult<Vec<u8>> {
    let mut buffer = vec![0xEF, 0xBB, 0xBF];
    {
        let mut writer = csv::WriterBuilder::new().terminator(csv::Terminator::CRLF).from_writer(&mut buffer);
        writer.write_record(CSV_HEADER)?;
        for (item, reminder) in rows {
            if item.deleted_at_ms.is_some() || item.text.is_empty() {
                continue;
            }
            writer.write_record([
                item.id.to_string(),
                apply_formula_guard(&item.text),
                item.status.as_str().to_owned(),
                rfc3339_utc_ms(item.created_at_ms),
                item.completed_at_ms.map(rfc3339_utc_ms).unwrap_or_default(),
                reminder.as_ref().map(|r| rfc3339_utc_ms(r.deadline_ms)).unwrap_or_default(),
                reminder.as_ref().map(|r| r.state().as_str().to_owned()).unwrap_or_default(),
            ])?;
        }
        writer.flush()?;
    }
    Ok(buffer)
}

fn encode(store: &Store, format: ExportFormat, rows: &[(Item, Option<Reminder>)]) -> CoreResult<Vec<u8>> {
    match format {
        ExportFormat::Json => encode_json(store, rows),
        ExportFormat::Csv => encode_csv(rows),
    }
}

/// Writes `bytes` atomically: a temp file in `path`'s own directory, `0600`,
/// then renamed over the destination. `overwrite` gates replacing an existing
/// file; the existence check happens before the (potentially slow) snapshot
/// work runs, so a missing `--force` fails fast. As with any check-then-act
/// over a filesystem, another process could recreate `path` between the
/// check and the final rename; this tool has one local user and does not
/// attempt to close that race with a nonstandard exclusive-rename syscall.
fn write_atomic(path: &Path, bytes: &[u8], overwrite: bool) -> CoreResult<()> {
    let parent = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };
    ensure_private_dir(parent)?;
    let temp_path = parent.join(format!(".rallo-export-{}.tmp", Uuid::new_v4()));
    let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temp_path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    if !overwrite && path.exists() {
        let _ = fs::remove_file(&temp_path);
        return Err(file_exists_error(path));
    }
    fs::rename(&temp_path, path)?;
    Ok(())
}

fn file_exists_error(path: &Path) -> CoreError {
    CoreError::conflict(
        ErrorCode::FileExists,
        format!("{} already exists; pass --force (overwrite: true) to replace it", path.display()),
    )
}

impl Store {
    /// The export document as bytes, for callers (the CLI's `--output -`,
    /// and later FFI) that want the content without touching a file.
    pub fn export_bytes(&self, format: ExportFormat) -> CoreResult<Vec<u8>> {
        let rows = snapshot(self)?;
        encode(self, format, &rows)
    }

    /// Writes the export to `path` atomically (0004): refuses to overwrite an
    /// existing file unless `overwrite`, mode `0600`. The existence check
    /// runs before the snapshot is read.
    pub fn export_to_file(&self, path: &Path, format: ExportFormat, overwrite: bool) -> CoreResult<ExportSummary> {
        if !overwrite && path.exists() {
            return Err(file_exists_error(path));
        }
        let rows = snapshot(self)?;
        let bytes = encode(self, format, &rows)?;
        write_atomic(path, &bytes, overwrite)?;
        let written =
            |item: &Item| !item.text.is_empty() && (format == ExportFormat::Json || item.deleted_at_ms.is_none());
        let items = rows.iter().filter(|(item, _)| written(item)).count();
        let left_out = rows
            .iter()
            .filter(|(item, _)| item.text.is_empty() && (format == ExportFormat::Json || item.deleted_at_ms.is_none()))
            .count();
        let images = images_repository::all(self.conn())?.len();
        let mut warnings = Vec::new();
        if images == 1 {
            warnings.push("1 image isn't included; use --format zip".to_owned());
        } else if images > 1 {
            warnings.push(format!("{images} images aren't included; use --format zip"));
        }
        if left_out == 1 {
            warnings.push("1 image-only note was left out".to_owned());
        } else if left_out > 1 {
            warnings.push(format!("{left_out} image-only notes were left out"));
        }
        Ok(ExportSummary { items: items as u64, path: path.to_path_buf(), warnings })
    }

    /// The zip export's contents (0018), written into `dir` (an empty
    /// directory the caller made): `rallo-export.json` (version 2, with each
    /// note's `images`) and `images/<item id>/<file>`. The platform crate
    /// zips the directory.
    pub fn export_to_dir(&self, dir: &Path) -> CoreResult<ExportSummary> {
        let rows = snapshot(self)?;
        let mut items = Vec::with_capacity(rows.len());
        for (item, reminder) in &rows {
            let images = images_repository::for_item(self.conn(), item.id)?;
            let mut exported = Vec::with_capacity(images.len());
            for image in images {
                let file = format!("{ARCHIVE_IMAGES_DIR}/{}/{}", item.id, image.file_name);
                let target = dir.join(&file);
                ensure_private_dir(target.parent().expect("has a parent"))?;
                fs::copy(crate::images::files::file_path(self.data_dir(), item.id, &image.file_name), &target)?;
                exported.push(ExportImage {
                    id: image.id,
                    file,
                    mime_type: image.mime_type,
                    bytes: image.byte_size,
                    created_at_ms: image.created_at_ms,
                });
            }
            items.push(export_item(item, reminder.as_ref(), Some(exported)));
        }
        let document = ExportDocument {
            format: EXPORT_FORMAT_TAG,
            version: EXPORT_VERSION,
            exported_at: rfc3339_utc_ms(self.now_ms()),
            core_version: crate::CORE_VERSION,
            schema_version: SCHEMA_VERSION,
            items,
        };
        let path = dir.join(ARCHIVE_DOCUMENT);
        write_atomic(&path, &serde_json::to_vec_pretty(&document).expect("ExportDocument serializes"), false)?;
        Ok(ExportSummary { items: rows.len() as u64, path, warnings: Vec::new() })
    }
}
