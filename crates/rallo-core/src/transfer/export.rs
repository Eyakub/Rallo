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
/// Version of the JSON backup document shape, independent of the database
/// schema version recorded alongside it.
pub const EXPORT_VERSION: u32 = 1;

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

fn export_item(item: &Item, reminder: Option<&Reminder>) -> ExportItem {
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
    }
}

fn encode_json(store: &Store, rows: &[(Item, Option<Reminder>)]) -> CoreResult<Vec<u8>> {
    let document = ExportDocument {
        format: EXPORT_FORMAT_TAG,
        version: EXPORT_VERSION,
        exported_at: rfc3339_utc_ms(store.now_ms()),
        core_version: crate::CORE_VERSION,
        schema_version: SCHEMA_VERSION,
        items: rows.iter().map(|(item, reminder)| export_item(item, reminder.as_ref())).collect(),
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
            if item.deleted_at_ms.is_some() {
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
        let items = match format {
            ExportFormat::Json => rows.len(),
            ExportFormat::Csv => rows.iter().filter(|(item, _)| item.deleted_at_ms.is_none()).count(),
        };
        Ok(ExportSummary { items: items as u64, path: path.to_path_buf() })
    }
}
