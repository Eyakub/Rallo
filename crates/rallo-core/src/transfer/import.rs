//! `rallo import` (build plan §5, §10; decision 0004): validates an entire
//! export document (JSON backup or CSV) before any write, classifies each
//! record as new/identical/conflict, and — outside a dry run — applies it in
//! one `BEGIN IMMEDIATE` transaction behind a pre-import backup snapshot.
//! See `docs/decisions/0004-export-import-formats.md` for the format shapes
//! and the classification rules this module implements.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use super::export::{ARCHIVE_DOCUMENT, EXPORT_FORMAT_TAG, EXPORT_VERSION, ExportFormat, rfc3339_utc_ms};
use super::formula_guard::strip_formula_guard;
use crate::images::repository as images_repository;
use crate::images::{ImageKind, MAX_IMAGE_BYTES, MAX_IMAGES_PER_NOTE, files as image_files};
use crate::items::model::{Item, ItemStatus};
use crate::items::repository as items_repository;
use crate::reminders::model::{InputKind, Reminder};
use crate::reminders::repository as reminders_repository;
use crate::shared::errors::{ConflictDetail, CoreError, CoreResult, ErrorCode};
use crate::shared::{ids, text};
use crate::storage::backup;
use crate::storage::database::{Store, bump_revision};

/// Reads a zip export's document from its unpacked directory, under the same
/// size cap as any import document.
fn read_archive_document(dir: &Path) -> CoreResult<Vec<u8>> {
    let path = dir.join(ARCHIVE_DOCUMENT);
    let missing = || CoreError::invalid(ErrorCode::InvalidImport, "the archive has no rallo-export.json");
    let length = std::fs::symlink_metadata(&path).ok().filter(|metadata| metadata.is_file()).ok_or_else(missing)?.len();
    if length > MAX_IMPORT_BYTES as u64 {
        return Err(CoreError::invalid(
            ErrorCode::InvalidImport,
            format!("import document is {length} bytes; the limit is {MAX_IMPORT_BYTES} bytes"),
        ));
    }
    Ok(std::fs::read(&path)?)
}

/// File-size cap enforced before any parsing (0004): both formats.
pub const MAX_IMPORT_BYTES: usize = 64 * 1024 * 1024;

/// Cap on how many conflicting records a rejected import reports; `total` on
/// `ConflictDetail::ImportConflicts` still carries the true count.
const MAX_REPORTED_CONFLICTS: usize = 20;

const CSV_KNOWN_COLUMNS: [&str; 7] =
    ["id", "text", "status", "created_at", "completed_at", "reminder_at", "reminder_state"];

/// One record's classification against the bounded id/line reference used in
/// error output. Never carries note text.
#[derive(Debug, Clone, Serialize)]
pub struct ImportConflictRecord {
    pub id: Option<Uuid>,
    pub line: Option<u64>,
    pub index: Option<u64>,
    pub reason: String,
}

/// Result of `preview_import`/`apply_import` (0004). `conflicts` is always
/// empty here: any conflict is reported as an `IMPORT_CONFLICT` error instead
/// (see `ConflictDetail::ImportConflicts`), never mixed into a success value.
#[derive(Debug, Clone, Serialize)]
pub struct ImportReport {
    pub format: ExportFormat,
    pub total_records: u64,
    pub new: u64,
    pub identical: u64,
    pub conflicts: Vec<ImportConflictRecord>,
    /// All conflicting records; `conflicts` lists at most 20 of them.
    pub conflict_total: u64,
    pub warnings: Vec<String>,
    pub applied: bool,
    pub backup_path: Option<PathBuf>,
}

#[derive(Debug, Clone)]
enum RecordOrigin {
    Json { index: usize },
    Csv { line: u64 },
}

impl RecordOrigin {
    fn index(&self) -> Option<u64> {
        match self {
            Self::Json { index } => Some(*index as u64),
            Self::Csv { .. } => None,
        }
    }

    fn line(&self) -> Option<u64> {
        match self {
            Self::Csv { line } => Some(*line),
            Self::Json { .. } => None,
        }
    }
}

/// A record's reminder, already validated but not yet assigned defaults that
/// only make sense at insert time (a fresh id, `now` as a fallback
/// timestamp).
struct NormalizedReminder {
    id: Option<Uuid>,
    deadline_ms: i64,
    time_input: String,
    input_kind: InputKind,
    input_offset_seconds: Option<i32>,
    created_at_ms: Option<i64>,
    updated_at_ms: Option<i64>,
}

/// One fully validated record, independent of its source format.
/// `created_at_ms`/`updated_at_ms` are `None` only when the source format
/// never carries them (CSV omitted the column): that absence is meaningful
/// for both dedupe (0004 §"identical") and defaulting at insert time, so it
/// is preserved rather than resolved eagerly.
struct NormalizedRecord {
    id: Option<Uuid>,
    text: String,
    status: ItemStatus,
    created_at_ms: Option<i64>,
    updated_at_ms: Option<i64>,
    completed_at_ms: Option<i64>,
    deleted_at_ms: Option<i64>,
    reminder: Option<NormalizedReminder>,
    /// Empty for CSV and version-1 JSON.
    images: Vec<NormalizedImage>,
    origin: RecordOrigin,
}

/// An image whose file in the archive directory has already been checked.
struct NormalizedImage {
    id: Uuid,
    kind: ImageKind,
    source: PathBuf,
    byte_size: i64,
    created_at_ms: i64,
}

struct ParsedDocument {
    format: ExportFormat,
    records: Vec<NormalizedRecord>,
    warnings: Vec<String>,
}

enum RecordDecision {
    New,
    Identical,
    Conflict,
}

fn invalid_import(origin: &RecordOrigin, field: &str, problem: &str) -> CoreError {
    let location = match origin {
        RecordOrigin::Json { index } => format!("record {index}"),
        RecordOrigin::Csv { line } => format!("line {line}"),
    };
    CoreError::invalid(ErrorCode::InvalidImport, format!("{location}: field \"{field}\" {problem}"))
}

fn validate_size(bytes: &[u8]) -> CoreResult<()> {
    if bytes.len() > MAX_IMPORT_BYTES {
        return Err(CoreError::invalid(
            ErrorCode::InvalidImport,
            format!("import document is {} bytes; the limit is {MAX_IMPORT_BYTES} bytes", bytes.len()),
        ));
    }
    Ok(())
}

fn parse_rfc3339_ms(origin: &RecordOrigin, field: &str, raw: &str) -> CoreResult<i64> {
    let parsed = OffsetDateTime::parse(raw, &Rfc3339)
        .map_err(|_| invalid_import(origin, field, "is not a valid RFC 3339 timestamp"))?;
    i64::try_from(parsed.unix_timestamp_nanos().div_euclid(1_000_000))
        .map_err(|_| invalid_import(origin, field, "is out of range"))
}

/// Format detection (0004): a JSON object tagged `"format": "rallo.export"`
/// is the backup; anything else (including malformed JSON) is read as CSV,
/// where it will fail its own validation if it is not that either.
fn parse_document(bytes: &[u8], archive: Option<&Path>) -> CoreResult<ParsedDocument> {
    let is_backup = serde_json::from_slice::<Value>(bytes)
        .ok()
        .and_then(|value| value.get("format").and_then(Value::as_str).map(str::to_owned))
        .is_some_and(|format| format == EXPORT_FORMAT_TAG);
    match (is_backup, archive) {
        (true, _) => parse_json_document(bytes, archive),
        (false, Some(_)) => Err(CoreError::invalid(
            ErrorCode::InvalidImport,
            "not a Rallo archive: rallo-export.json isn't a Rallo export",
        )),
        (false, None) => parse_csv_document(bytes),
    }
}

// --- JSON backup ---------------------------------------------------------

#[derive(Deserialize)]
struct RawDocument {
    format: String,
    version: u32,
    #[serde(default)]
    items: Vec<RawItem>,
}

#[derive(Deserialize)]
struct RawItem {
    id: String,
    text: String,
    status: String,
    created_at_ms: i64,
    updated_at_ms: i64,
    completed_at_ms: Option<i64>,
    deleted_at_ms: Option<i64>,
    #[serde(default)]
    reminder: Option<RawReminder>,
    #[serde(default)]
    images: Vec<RawImage>,
}

#[derive(Deserialize)]
struct RawImage {
    id: String,
    file: String,
    #[serde(rename = "type")]
    mime_type: String,
    created_at_ms: i64,
}

#[derive(Deserialize)]
struct RawReminder {
    id: String,
    deadline_ms: i64,
    time_input: String,
    input_kind: String,
    input_offset_seconds: Option<i32>,
    state: String,
    acknowledged_at_ms: Option<i64>,
    created_at_ms: i64,
    updated_at_ms: i64,
}

fn parse_json_document(bytes: &[u8], archive: Option<&Path>) -> CoreResult<ParsedDocument> {
    let doc: RawDocument = serde_json::from_slice(bytes)
        .map_err(|error| CoreError::invalid(ErrorCode::InvalidImport, format!("malformed export document: {error}")))?;
    if doc.format != EXPORT_FORMAT_TAG {
        return Err(CoreError::invalid(ErrorCode::InvalidImport, "not a Rallo export document"));
    }
    if doc.version > EXPORT_VERSION {
        return Err(CoreError::IncompatibleSchema { found: doc.version, supported: EXPORT_VERSION });
    }
    let mut seen_ids = HashSet::new();
    let mut seen_images = HashSet::new();
    let mut records = Vec::with_capacity(doc.items.len());
    for (index, raw) in doc.items.into_iter().enumerate() {
        let record = normalize_json_item(index, raw, &mut seen_ids, archive)?;
        for image in &record.images {
            if !seen_images.insert(image.id) {
                return Err(CoreError::invalid(
                    ErrorCode::InvalidImport,
                    format!("image ID {} appears twice", image.id),
                ));
            }
        }
        records.push(record);
    }
    Ok(ParsedDocument { format: ExportFormat::Json, records, warnings: Vec::new() })
}

fn normalize_json_image(
    origin: &RecordOrigin,
    item_id: Uuid,
    raw: RawImage,
    archive: &Path,
) -> CoreResult<NormalizedImage> {
    let id = Uuid::parse_str(&raw.id).map_err(|_| invalid_import(origin, "images", "has an id that is not a UUID"))?;
    let kind = ImageKind::from_mime_type(&raw.mime_type)
        .ok_or_else(|| invalid_import(origin, "images", "has a type Rallo cannot store"))?;
    if raw.file != format!("images/{item_id}/{id}.{}", kind.extension()) {
        return Err(invalid_import(origin, "images", "names a file outside images/<note id>/"));
    }
    let source = archive.join(&raw.file);
    let metadata = std::fs::symlink_metadata(&source)
        .ok()
        .filter(|metadata| metadata.is_file())
        .ok_or_else(|| invalid_import(origin, "images", "names a file the archive does not have"))?;
    if metadata.len() == 0 || metadata.len() > MAX_IMAGE_BYTES as u64 {
        return Err(invalid_import(origin, "images", "names an empty or oversized file"));
    }
    let mut head = [0u8; 12];
    let read = std::fs::File::open(&source).and_then(|mut file| std::io::Read::read(&mut file, &mut head));
    if !read.is_ok_and(|read| ImageKind::sniff(&head[..read]) == Some(kind)) {
        return Err(invalid_import(origin, "images", "names a file that is not the image type it says"));
    }
    Ok(NormalizedImage { id, kind, source, byte_size: metadata.len() as i64, created_at_ms: raw.created_at_ms })
}

fn normalize_json_item(
    index: usize,
    raw: RawItem,
    seen_ids: &mut HashSet<Uuid>,
    archive: Option<&Path>,
) -> CoreResult<NormalizedRecord> {
    let origin = RecordOrigin::Json { index };
    let id = Uuid::parse_str(&raw.id).map_err(|_| invalid_import(&origin, "id", "is not a valid UUID"))?;
    if !seen_ids.insert(id) {
        return Err(invalid_import(&origin, "id", "is a duplicate within this document"));
    }
    let status = ItemStatus::parse(&raw.status)
        .ok_or_else(|| invalid_import(&origin, "status", "must be \"open\" or \"done\""))?;
    text::validate_note_content(&raw.text, !raw.images.is_empty())
        .map_err(|_| invalid_import(&origin, "text", "is empty or exceeds the size limit"))?;
    if raw.images.len() > MAX_IMAGES_PER_NOTE {
        return Err(invalid_import(&origin, "images", "has more than 10 images"));
    }
    let images = match (archive, raw.images.is_empty()) {
        (_, true) => Vec::new(),
        (None, false) => {
            return Err(CoreError::invalid(
                ErrorCode::InvalidImport,
                "this export has images; import the .zip it came in",
            ));
        }
        (Some(archive), false) => raw
            .images
            .into_iter()
            .map(|image| normalize_json_image(&origin, id, image, archive))
            .collect::<CoreResult<Vec<_>>>()?,
    };
    if (status == ItemStatus::Done) != raw.completed_at_ms.is_some() {
        return Err(invalid_import(&origin, "completed_at_ms", "must be set if and only if status is \"done\""));
    }
    let reminder = raw.reminder.map(|reminder| normalize_json_reminder(&origin, reminder)).transpose()?;
    Ok(NormalizedRecord {
        id: Some(id),
        text: raw.text,
        status,
        created_at_ms: Some(raw.created_at_ms),
        updated_at_ms: Some(raw.updated_at_ms),
        completed_at_ms: raw.completed_at_ms,
        deleted_at_ms: raw.deleted_at_ms,
        reminder,
        images,
        origin,
    })
}

fn normalize_json_reminder(origin: &RecordOrigin, raw: RawReminder) -> CoreResult<NormalizedReminder> {
    let id = Uuid::parse_str(&raw.id).map_err(|_| invalid_import(origin, "reminder.id", "is not a valid UUID"))?;
    let input_kind = InputKind::parse(&raw.input_kind)
        .ok_or_else(|| invalid_import(origin, "reminder.input_kind", "must be \"relative\" or \"absolute\""))?;
    if raw.time_input.trim().is_empty() {
        return Err(invalid_import(origin, "reminder.time_input", "must not be empty"));
    }
    if !matches!(raw.state.as_str(), "active" | "acknowledged" | "cancelled" | "completed" | "deleted") {
        return Err(invalid_import(origin, "reminder.state", "is not a recognized reminder state"));
    }
    if (raw.state == "acknowledged") != raw.acknowledged_at_ms.is_some() {
        return Err(invalid_import(
            origin,
            "reminder.acknowledged_at_ms",
            "must be set if and only if state is \"acknowledged\"",
        ));
    }
    Ok(NormalizedReminder {
        id: Some(id),
        deadline_ms: raw.deadline_ms,
        time_input: raw.time_input,
        input_kind,
        input_offset_seconds: raw.input_offset_seconds,
        created_at_ms: Some(raw.created_at_ms),
        updated_at_ms: Some(raw.updated_at_ms),
    })
}

// --- CSV -------------------------------------------------------------------

fn strip_bom(bytes: &[u8]) -> &[u8] {
    bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes)
}

/// Trimmed, empty-as-absent lookup for the optional structured columns.
/// `text` is read separately and never trimmed: leading/trailing whitespace
/// in note text is content, not formatting (0004).
fn field<'a>(row: &'a csv::StringRecord, index_of: &HashMap<String, usize>, key: &str) -> Option<&'a str> {
    index_of.get(key).and_then(|&i| row.get(i)).map(str::trim).filter(|value| !value.is_empty())
}

fn parse_csv_document(bytes: &[u8]) -> CoreResult<ParsedDocument> {
    let bytes = strip_bom(bytes);
    let mut reader = csv::ReaderBuilder::new().has_headers(true).flexible(true).from_reader(bytes);
    let headers = reader.headers()?.clone();

    let mut index_of: HashMap<String, usize> = HashMap::new();
    let mut warnings = Vec::new();
    for (position, name) in headers.iter().enumerate() {
        let trimmed = name.trim();
        let lower = trimmed.to_ascii_lowercase();
        if CSV_KNOWN_COLUMNS.contains(&lower.as_str()) {
            index_of.insert(lower, position);
        } else if !trimmed.is_empty() {
            warnings.push(format!("unknown CSV column \"{trimmed}\" ignored"));
        }
    }
    let text_idx = *index_of.get("text").ok_or_else(|| {
        CoreError::invalid(ErrorCode::InvalidImport, "CSV header is missing a required \"text\" column")
    })?;

    let mut seen_ids = HashSet::new();
    let mut records = Vec::new();
    for result in reader.records() {
        let row = result?;
        let line = row.position().map(csv::Position::line).unwrap_or(0);
        let origin = RecordOrigin::Csv { line };
        records.push(normalize_csv_row(&origin, &row, &index_of, text_idx, &mut seen_ids)?);
    }
    Ok(ParsedDocument { format: ExportFormat::Csv, records, warnings })
}

fn normalize_csv_row(
    origin: &RecordOrigin,
    row: &csv::StringRecord,
    index_of: &HashMap<String, usize>,
    text_idx: usize,
    seen_ids: &mut HashSet<Uuid>,
) -> CoreResult<NormalizedRecord> {
    let id = match field(row, index_of, "id") {
        None => None,
        Some(raw) => {
            let id = Uuid::parse_str(raw).map_err(|_| invalid_import(origin, "id", "is not a valid UUID"))?;
            if !seen_ids.insert(id) {
                return Err(invalid_import(origin, "id", "is a duplicate within this document"));
            }
            Some(id)
        }
    };

    let text = strip_formula_guard(row.get(text_idx).unwrap_or(""));
    text::validate_note_text(&text)
        .map_err(|_| invalid_import(origin, "text", "is empty or exceeds the size limit"))?;

    let status = match field(row, index_of, "status") {
        None => ItemStatus::Open,
        Some(raw) => ItemStatus::parse(&raw.to_ascii_lowercase())
            .ok_or_else(|| invalid_import(origin, "status", "must be \"open\" or \"done\""))?,
    };

    let created_at_ms =
        field(row, index_of, "created_at").map(|raw| parse_rfc3339_ms(origin, "created_at", raw)).transpose()?;
    let completed_at_ms =
        field(row, index_of, "completed_at").map(|raw| parse_rfc3339_ms(origin, "completed_at", raw)).transpose()?;
    if (status == ItemStatus::Done) != completed_at_ms.is_some() {
        return Err(invalid_import(origin, "completed_at", "must be set if and only if status is \"done\""));
    }

    let reminder_at =
        field(row, index_of, "reminder_at").map(|raw| parse_rfc3339_ms(origin, "reminder_at", raw)).transpose()?;
    let reminder_state = field(row, index_of, "reminder_state");
    if reminder_state.is_some() && reminder_at.is_none() {
        return Err(invalid_import(origin, "reminder_state", "requires \"reminder_at\" to also be set"));
    }
    if let Some(state) = reminder_state
        && !matches!(state, "active" | "acknowledged" | "cancelled" | "completed" | "deleted")
    {
        return Err(invalid_import(origin, "reminder_state", "is not a recognized reminder state"));
    }
    // CSV only carries a resolved deadline, never a verbatim "--in"/"--at"
    // input; it is treated as an absolute UTC deadline (0004).
    let reminder = reminder_at.map(|deadline_ms| NormalizedReminder {
        id: None,
        deadline_ms,
        time_input: rfc3339_utc_ms(deadline_ms),
        input_kind: InputKind::Absolute,
        input_offset_seconds: Some(0),
        created_at_ms: None,
        updated_at_ms: None,
    });

    Ok(NormalizedRecord {
        id,
        text,
        status,
        created_at_ms,
        updated_at_ms: None,
        completed_at_ms,
        deleted_at_ms: None,
        reminder,
        images: Vec::new(),
        origin: origin.clone(),
    })
}

// --- Classification ----------------------------------------------------

/// Compares a record against the item (and reminder) it claims to match.
/// Only fields the format actually carries verbatim take part:
/// `created_at_ms`/`updated_at_ms` are compared only when the record gives
/// one (CSV may omit them); the reminder's identity for this purpose is its
/// resolved deadline, not its raw enabled/state bookkeeping — import always
/// normalizes an inserted reminder to disabled/`imported`, so comparing that
/// bookkeeping would make every legitimate re-import look like a conflict
/// (0004).
fn fields_match(record: &NormalizedRecord, existing: &Item, existing_reminder: Option<&Reminder>) -> bool {
    if record.text != existing.text || record.status != existing.status {
        return false;
    }
    if let Some(value) = record.created_at_ms
        && value != existing.created_at_ms
    {
        return false;
    }
    if let Some(value) = record.updated_at_ms
        && value != existing.updated_at_ms
    {
        return false;
    }
    if record.completed_at_ms != existing.completed_at_ms || record.deleted_at_ms != existing.deleted_at_ms {
        return false;
    }
    match (&record.reminder, existing_reminder) {
        (None, None) => true,
        (Some(record_reminder), Some(existing_reminder)) => {
            record_reminder.deadline_ms == existing_reminder.deadline_ms
        }
        _ => false,
    }
}

/// Classifies one record (0004): an id identifies an existing item exactly
/// (new / identical / conflict). An id-less row (CSV only) has no identity
/// assertion to conflict with — it is either an exact duplicate of an
/// existing item's text and `created_at` (identical) or a fresh row (new);
/// with neither an id nor a `created_at` it is always new.
fn classify_record(conn: &Connection, record: &NormalizedRecord) -> CoreResult<RecordDecision> {
    match record.id {
        Some(id) => match items_repository::get_by_id(conn, id)? {
            None => Ok(RecordDecision::New),
            Some(existing) => {
                let existing_reminder = reminders_repository::fetch_by_item(conn, id)?;
                if fields_match(record, &existing, existing_reminder.as_ref()) {
                    Ok(RecordDecision::Identical)
                } else {
                    Ok(RecordDecision::Conflict)
                }
            }
        },
        None => match record.created_at_ms {
            None => Ok(RecordDecision::New),
            Some(created_at_ms) => {
                let existing = items_repository::find_by_exact_text_and_created_at(conn, &record.text, created_at_ms)?;
                Ok(if existing.is_some() { RecordDecision::Identical } else { RecordDecision::New })
            }
        },
    }
}

/// Classifies every record, collecting (bounded) conflicts instead of
/// failing on them.
fn classify_collect(
    conn: &Connection,
    records: &[NormalizedRecord],
) -> CoreResult<(Vec<RecordDecision>, Vec<ImportConflictRecord>, u64)> {
    let mut decisions = Vec::with_capacity(records.len());
    let mut conflicts = Vec::new();
    for record in records {
        let decision = classify_record(conn, record)?;
        if matches!(decision, RecordDecision::New)
            && let Some(image) = record.images.iter().find(|image| images_repository::exists(conn, image.id))
        {
            return Err(CoreError::invalid(
                ErrorCode::InvalidImport,
                format!("image ID {} is already in Rallo", image.id),
            ));
        }
        if matches!(decision, RecordDecision::Conflict) {
            conflicts.push(ImportConflictRecord {
                id: record.id,
                line: record.origin.line(),
                index: record.origin.index(),
                reason: "matches an existing item's id with different content".to_owned(),
            });
        }
        decisions.push(decision);
    }
    let total = conflicts.len() as u64;
    conflicts.truncate(MAX_REPORTED_CONFLICTS);
    Ok((decisions, conflicts, total))
}

/// Classifies every record. Any conflict aborts with the full bounded list
/// (0004): nothing is written, whether this runs against a read-only
/// connection (preview) or inside the write transaction `apply_import` is
/// about to use.
fn classify_all(conn: &Connection, records: &[NormalizedRecord]) -> CoreResult<Vec<RecordDecision>> {
    let (decisions, conflicts, total) = classify_collect(conn, records)?;
    if total > 0 {
        return Err(CoreError::conflict_detail(
            ErrorCode::ImportConflict,
            format!("{total} record(s) conflict with an existing item; nothing was imported"),
            ConflictDetail::ImportConflicts { total, conflicts },
        ));
    }
    Ok(decisions)
}

fn build_report(
    parsed: &ParsedDocument,
    decisions: &[RecordDecision],
    applied: bool,
    backup_path: Option<PathBuf>,
) -> ImportReport {
    let new = decisions.iter().filter(|decision| matches!(decision, RecordDecision::New)).count() as u64;
    let identical = decisions.iter().filter(|decision| matches!(decision, RecordDecision::Identical)).count() as u64;
    ImportReport {
        format: parsed.format,
        total_records: parsed.records.len() as u64,
        new,
        identical,
        conflicts: Vec::new(),
        conflict_total: 0,
        warnings: parsed.warnings.clone(),
        applied,
        backup_path,
    }
}

/// Inserts one `New` record (0004): revision 1, and — if it carries a
/// reminder — always disabled with `disabled_reason = 'imported'`,
/// generation 1, no notification intent.
fn insert_record(
    tx: &Transaction<'_>,
    record: &NormalizedRecord,
    now_ms: i64,
    data_dir: &Path,
    copied: &mut Vec<PathBuf>,
) -> CoreResult<()> {
    let id = record.id.unwrap_or_else(ids::new_id);
    let created_at_ms = record.created_at_ms.unwrap_or(now_ms);
    let updated_at_ms = record.updated_at_ms.unwrap_or(created_at_ms);
    let item = Item {
        id,
        short_key: ids::short_key(&id),
        text: record.text.clone(),
        status: record.status,
        created_at_ms,
        updated_at_ms,
        completed_at_ms: record.completed_at_ms,
        deleted_at_ms: record.deleted_at_ms,
        revision: 1,
    };
    items_repository::insert(tx, &item, &text::match_key(&item.text))?;
    if let Some(reminder) = &record.reminder {
        let reminder_id = reminder.id.unwrap_or_else(ids::new_id);
        let reminder_created_at_ms = reminder.created_at_ms.unwrap_or(created_at_ms);
        let reminder_updated_at_ms = reminder.updated_at_ms.unwrap_or(reminder_created_at_ms);
        reminders_repository::insert_imported(
            tx,
            reminder_id,
            id,
            reminder.deadline_ms,
            &reminder.time_input,
            reminder.input_kind,
            reminder.input_offset_seconds,
            reminder_created_at_ms,
            reminder_updated_at_ms,
        )?;
    }
    for (position, image) in record.images.iter().enumerate() {
        copied.push(image_files::copy_in(data_dir, id, image.id, image.kind, &image.source)?);
        images_repository::insert_imported(
            tx,
            id,
            image.id,
            image.kind,
            image.byte_size,
            position as i64,
            image.created_at_ms,
        )?;
    }
    Ok(())
}

impl Store {
    /// Validates and classifies an import document without writing anything
    /// (0004): `rallo import --dry-run`. Any conflict fails the whole call —
    /// the same rule `apply_import` enforces — so a dry run's exit code
    /// matches what a real import would do.
    pub fn preview_import(&self, bytes: &[u8]) -> CoreResult<ImportReport> {
        validate_size(bytes)?;
        let parsed = parse_document(bytes, None)?;
        let decisions = classify_all(self.conn(), &parsed.records)?;
        Ok(build_report(&parsed, &decisions, false, None))
    }

    /// Like `preview_import`, but reports conflicts in the returned report
    /// (`conflicts`, `conflict_total`) instead of failing, so an interactive
    /// review can show them. Writes nothing.
    pub fn inspect_import(&self, bytes: &[u8]) -> CoreResult<ImportReport> {
        validate_size(bytes)?;
        self.inspect_parsed(parse_document(bytes, None)?)
    }

    /// `inspect_import` for an unzipped archive (0018): conflicts are in
    /// the report, nothing is written.
    pub fn inspect_import_dir(&self, dir: &Path) -> CoreResult<ImportReport> {
        let bytes = read_archive_document(dir)?;
        self.inspect_parsed(parse_document(&bytes, Some(dir))?)
    }

    fn inspect_parsed(&self, parsed: ParsedDocument) -> CoreResult<ImportReport> {
        let (decisions, conflicts, total) = classify_collect(self.conn(), &parsed.records)?;
        let mut report = build_report(&parsed, &decisions, false, None);
        report.conflicts = conflicts;
        report.conflict_total = total;
        Ok(report)
    }

    /// Validates, re-classifies, and applies an import document in one
    /// `BEGIN IMMEDIATE` transaction (0004). A pre-import SQLite backup
    /// snapshot is taken before any row is written; `change_revision` bumps
    /// once if anything was inserted. Any conflict writes nothing (no backup
    /// either).
    ///
    /// Classification runs twice: once against the connection's current
    /// committed state (so a document that cannot apply never touches the
    /// filesystem for a backup), and again inside the `BEGIN IMMEDIATE`
    /// transaction right before applying, to catch a conflict introduced by
    /// a concurrent writer in between. The SQLite online backup API is taken
    /// on a plain (non-transactional) connection deliberately: run against a
    /// connection with its own transaction already open, it never returns.
    pub fn apply_import(&mut self, bytes: &[u8]) -> CoreResult<ImportReport> {
        validate_size(bytes)?;
        self.apply_parsed(parse_document(bytes, None)?)
    }

    /// `preview_import` for a zip export's unpacked directory (0018).
    pub fn preview_import_dir(&self, dir: &Path) -> CoreResult<ImportReport> {
        let bytes = read_archive_document(dir)?;
        let parsed = parse_document(&bytes, Some(dir))?;
        let decisions = classify_all(self.conn(), &parsed.records)?;
        Ok(build_report(&parsed, &decisions, false, None))
    }

    /// `apply_import` for a zip export's unpacked directory (0018): every
    /// image file is checked before anything is written.
    pub fn apply_import_dir(&mut self, dir: &Path) -> CoreResult<ImportReport> {
        let bytes = read_archive_document(dir)?;
        self.apply_parsed(parse_document(&bytes, Some(dir))?)
    }

    fn apply_parsed(&mut self, parsed: ParsedDocument) -> CoreResult<ImportReport> {
        classify_all(self.conn(), &parsed.records)?;

        let now = self.now_ms();
        let backup_path =
            backup::snapshot(self.conn(), &self.data_dir().join("backups").join(format!("pre-import-{now}.sqlite3")))?;

        let data_dir = self.data_dir().to_path_buf();
        let tx = self.write_tx()?;
        let decisions = match classify_all(&tx, &parsed.records) {
            Ok(decisions) => decisions,
            Err(error) => {
                let _ = std::fs::remove_file(&backup_path);
                return Err(error);
            }
        };

        // Image files are copied inside the transaction (imports are rare
        // and user-initiated), so rows and files stay in step: on any
        // failure the files copied so far are removed and the rows roll back.
        let mut copied = Vec::new();
        let applied: CoreResult<()> = (|| {
            let mut inserted: u64 = 0;
            for (record, decision) in parsed.records.iter().zip(&decisions) {
                if matches!(decision, RecordDecision::New) {
                    insert_record(&tx, record, now, &data_dir, &mut copied)?;
                    inserted += 1;
                }
            }
            if inserted > 0 {
                bump_revision(&tx)?;
            }
            Ok(())
        })();
        let applied = applied.and_then(|()| tx.commit().map_err(CoreError::from));
        if let Err(error) = applied {
            for path in &copied {
                let _ = std::fs::remove_file(path);
            }
            for dir in copied.iter().filter_map(|path| path.parent()) {
                let _ = std::fs::remove_dir(dir);
            }
            if let Some(root) = copied.first().and_then(|path| path.parent()).and_then(Path::parent) {
                let _ = std::fs::remove_dir(root);
            }
            return Err(error);
        }

        Ok(build_report(&parsed, &decisions, true, Some(backup_path)))
    }
}
