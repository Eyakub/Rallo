//! Decision 0004: export/import formats, validation, classification, and
//! atomic file writing.

mod support;

use std::sync::Arc;
use std::thread;

use rallo_core::items::{ListFilter, ListQuery};
use rallo_core::reminders::{ReminderState, TimeSpec};
use rallo_core::shared::clock::ManualClock;
use rallo_core::shared::errors::ConflictDetail;
use rallo_core::transfer::ExportFormat;
use rallo_core::{ErrorCode, Store, StoreOptions};
use serde_json::{Value, json};
use uuid::Uuid;

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

fn all_items(store: &Store) -> Vec<rallo_core::items::ItemView> {
    store.list(ListQuery { filter: ListFilter::All, limit: 200, cursor: None }).unwrap().items
}

fn deleted_items(store: &Store) -> Vec<rallo_core::items::ItemView> {
    store.list(ListQuery { filter: ListFilter::Deleted, limit: 200, cursor: None }).unwrap().items
}

// --- JSON backup: round trip, re-import, conflicts, validation ------------

#[test]
fn json_round_trip_into_fresh_store_preserves_everything_and_disables_the_reminder() {
    let source = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000_000));
    let mut a = open_with_clock(source.path(), clock.clone());

    let plain = a.create_note("plain note", None).unwrap().item.item;
    clock.advance(1_000);
    let reminded = a.create_reminder("remind me", &TimeSpec::In("20m".into()), None).unwrap().item.item;
    clock.advance(1_000);
    let done = a.create_note("finish this", None).unwrap().item.item;
    let done = a.complete(&done.id.to_string(), &Default::default()).unwrap().item.item;
    clock.advance(1_000);
    let gone = a.create_note("throwaway", None).unwrap().item.item;
    let gone = a.delete(&gone.id.to_string(), &Default::default()).unwrap().item.item;

    let bytes = a.export_bytes(ExportFormat::Json).unwrap();

    let target = tempfile::tempdir().unwrap();
    let mut b = support::open(target.path());
    let report = b.apply_import(&bytes).unwrap();
    assert_eq!(report.total_records, 4);
    assert_eq!(report.new, 4);
    assert_eq!(report.identical, 0);
    assert!(report.conflicts.is_empty());
    assert!(report.applied);
    assert!(report.backup_path.is_some());

    for original in [&plain, &reminded, &done, &gone] {
        let view = b.get_item(&original.id.to_string()).unwrap();
        assert_eq!(view.item.text, original.text, "text preserved for {}", original.id);
        assert_eq!(view.item.status, original.status);
        assert_eq!(view.item.created_at_ms, original.created_at_ms);
        assert_eq!(view.item.updated_at_ms, original.updated_at_ms);
        assert_eq!(view.item.completed_at_ms, original.completed_at_ms);
        assert_eq!(view.item.deleted_at_ms, original.deleted_at_ms);
        assert_eq!(view.item.revision, 1, "imported items always start at revision 1");
    }

    let imported_reminder = b.get_item(&reminded.id.to_string()).unwrap();
    let reminder = imported_reminder.reminder.as_ref().expect("the reminder round-tripped");
    let original_reminder = a.get_item(&reminded.id.to_string()).unwrap().reminder.unwrap();
    assert_eq!(reminder.deadline_ms, original_reminder.deadline_ms, "deadline preserved");
    // Imported reminders are always disabled (0003 disabled_reason 'imported'
    // surfaces as the ordinary "cancelled" derived state; verified against
    // the raw row below for the exact reason).
    assert_eq!(reminder.state(), ReminderState::Cancelled);

    let raw = support::raw_connection(target.path());
    let (enabled, disabled_reason, generation): (i64, String, i64) = raw
        .query_row(
            "SELECT enabled, disabled_reason, generation FROM reminders WHERE item_id = ?1",
            [reminded.id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!((enabled, disabled_reason.as_str(), generation), (0, "imported", 1));
    let intents: i64 = raw
        .query_row(
            "SELECT COUNT(*) FROM notification_intents WHERE reminder_id =
                (SELECT id FROM reminders WHERE item_id = ?1)",
            [reminded.id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(intents, 0, "import never queues a notification intent");

    assert_eq!(deleted_items(&b).len(), 1, "deleted items are preserved on import");
}

#[test]
fn reimporting_the_same_json_file_is_all_identical_and_writes_nothing() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    a.create_note("first", None).unwrap();
    a.create_reminder("second", &TimeSpec::In("10m".into()), None).unwrap();
    let bytes = a.export_bytes(ExportFormat::Json).unwrap();

    let target = tempfile::tempdir().unwrap();
    let mut b = support::open(target.path());
    let first = b.apply_import(&bytes).unwrap();
    assert_eq!((first.new, first.identical), (2, 0));
    let revision_after_first = b.change_revision().unwrap();

    let second = b.apply_import(&bytes).unwrap();
    assert_eq!((second.new, second.identical), (0, 2));
    assert!(second.conflicts.is_empty());
    assert_eq!(b.change_revision().unwrap(), revision_after_first, "nothing changed on a fully identical re-import");
    assert_eq!(all_items(&b).len(), 2, "no duplicates were created");
}

#[test]
fn conflict_same_id_edited_text_aborts_with_nothing_written() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    let item = a.create_note("original text", None).unwrap().item.item;
    let bytes = a.export_bytes(ExportFormat::Json).unwrap();

    let target = tempfile::tempdir().unwrap();
    let mut b = support::open(target.path());
    b.apply_import(&bytes).unwrap();
    let revision_before = b.change_revision().unwrap();

    let mut document: Value = serde_json::from_slice(&bytes).unwrap();
    document["items"][0]["text"] = json!("edited text — a different note entirely");
    let edited_bytes = serde_json::to_vec(&document).unwrap();

    let error = b.apply_import(&edited_bytes).unwrap_err();
    assert_eq!(error.code(), ErrorCode::ImportConflict);
    match error.detail() {
        Some(ConflictDetail::ImportConflicts { total, conflicts }) => {
            assert_eq!(*total, 1);
            assert_eq!(conflicts[0].id, Some(item.id));
        }
        other => panic!("expected ImportConflicts detail, got {other:?}"),
    }

    assert_eq!(b.change_revision().unwrap(), revision_before, "nothing changed on a rejected import");
    assert_eq!(b.get_item(&item.id.to_string()).unwrap().item.text, "original text");

    // A dry run reports the identical conflict without writing either.
    let preview_error = b.preview_import(&edited_bytes).unwrap_err();
    assert_eq!(preview_error.code(), ErrorCode::ImportConflict);
}

#[test]
fn invalid_documents_are_rejected_before_any_write() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    a.create_note("seed", None).unwrap();
    let bytes = a.export_bytes(ExportFormat::Json).unwrap();
    let base: Value = serde_json::from_slice(&bytes).unwrap();

    let target = tempfile::tempdir().unwrap();
    let mut store = support::open(target.path());

    let mut case = |mutate: &dyn Fn(&mut Value)| {
        let mut document = base.clone();
        mutate(&mut document);
        let bytes = serde_json::to_vec(&document).unwrap();
        let error = store.apply_import(&bytes).unwrap_err();
        assert!(
            matches!(error.code(), ErrorCode::InvalidImport | ErrorCode::IncompatibleSchema),
            "unexpected code: {:?}",
            error.code()
        );
        assert_eq!(all_items(&store).len(), 0, "nothing committed for: {document}");
    };

    case(&|doc| doc["version"] = json!(999));
    case(&|doc| doc["items"][0]["id"] = json!("not-a-uuid"));
    case(&|doc| doc["items"][0]["text"] = json!(""));
    case(&|doc| doc["items"][0]["text"] = json!("a".repeat(64 * 1024 + 1)));
    case(&|doc| doc["items"][0]["status"] = json!("done")); // completed_at_ms stays null
    case(&|doc| {
        doc["items"][0]["status"] = json!("open");
        doc["items"][0]["completed_at_ms"] = json!(1_234);
    });
    case(&|doc| {
        let item = doc["items"][0].clone();
        doc["items"] = json!([item.clone(), item]); // duplicate id
    });
    // Structurally invalid JSON tagged as a Rallo export (a field with the
    // wrong type): genuinely non-JSON garbage bytes fall through to CSV
    // detection instead (checked separately below) since format detection is
    // content-based, not a parse-or-reject gate.
    case(&|doc| doc["items"][0]["created_at_ms"] = json!("not a number"));

    let garbage = store.apply_import(b"\x00\x01 not json and not csv either \xff").unwrap_err();
    assert_eq!(garbage.code(), ErrorCode::InvalidImport);
    assert_eq!(all_items(&store).len(), 0);

    let oversized = vec![b'a'; rallo_core::transfer::MAX_IMPORT_BYTES + 1];
    let error = store.apply_import(&oversized).unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidImport);
}

// --- CSV: quoting, formula guard, BOM, headers, id-less dedupe ------------

#[test]
fn csv_round_trip_preserves_tricky_text_and_new_records_land_on_reimport() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    let texts = [
        "has, a comma",
        "has \"a quote\"",
        "embedded\r\ncrlf newline",
        "embedded\nlf only",
        "unicode héllo wörld",
        "emoji 🎉🚀 party",
        "   leading spaces",
    ];
    let ids: Vec<Uuid> = texts.iter().map(|text| a.create_note(text, None).unwrap().item.item.id).collect();

    let bytes = a.export_bytes(ExportFormat::Csv).unwrap();

    let target = tempfile::tempdir().unwrap();
    let mut b = support::open(target.path());
    let report = b.apply_import(&bytes).unwrap();
    assert_eq!(report.new, texts.len() as u64);

    for (id, text) in ids.iter().zip(texts) {
        assert_eq!(b.get_item(&id.to_string()).unwrap().item.text, text, "exact text preserved for {text:?}");
    }
}

#[test]
fn formula_guard_round_trips_through_csv_export_and_import() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    let formula = a.create_note("=SUM(A1:A2)", None).unwrap().item.item;
    let plus = a.create_note("+1 more thing", None).unwrap().item.item;
    let plain = a.create_note("nothing special", None).unwrap().item.item;
    let tabbed = a.create_note("\tindented", None).unwrap().item.item;
    let quoted = a.create_note("'=already quoted", None).unwrap().item.item;

    let bytes = a.export_bytes(ExportFormat::Csv).unwrap();
    let text = String::from_utf8(bytes[3..].to_vec()).unwrap(); // skip the BOM
    assert!(text.contains("'=SUM(A1:A2)"), "export guards a leading '=': {text}");
    assert!(text.contains("'+1 more thing"), "export guards a leading '+': {text}");

    let target = tempfile::tempdir().unwrap();
    let mut b = support::open(target.path());
    b.apply_import(&bytes).unwrap();

    assert_eq!(b.get_item(&formula.id.to_string()).unwrap().item.text, "=SUM(A1:A2)");
    assert_eq!(b.get_item(&plus.id.to_string()).unwrap().item.text, "+1 more thing");
    assert_eq!(b.get_item(&plain.id.to_string()).unwrap().item.text, "nothing special");
    assert_eq!(b.get_item(&tabbed.id.to_string()).unwrap().item.text, "\tindented");
    assert_eq!(b.get_item(&quoted.id.to_string()).unwrap().item.text, "'=already quoted");
}

#[test]
fn csv_export_has_a_utf8_bom_and_import_strips_it() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    a.create_note("bom check", None).unwrap();
    let bytes = a.export_bytes(ExportFormat::Csv).unwrap();
    assert_eq!(&bytes[..3], [0xEF, 0xBB, 0xBF], "UTF-8 BOM present for Excel encoding detection");

    let target = tempfile::tempdir().unwrap();
    let mut b = support::open(target.path());
    let report = b.apply_import(&bytes).unwrap();
    assert_eq!(report.new, 1, "the BOM did not get treated as part of the header or first field");
}

#[test]
fn csv_header_is_case_insensitive_and_unknown_columns_warn() {
    let csv = "ID,Text,STATUS,Created_At,Mystery\r\n\
               ,hand-made row,,,nonsense\r\n";
    let target = tempfile::tempdir().unwrap();
    let store = support::open(target.path());
    let report = store.preview_import(csv.as_bytes()).unwrap();
    assert_eq!(report.new, 1);
    assert!(report.warnings.iter().any(|w| w.contains("Mystery")), "{:?}", report.warnings);
}

#[test]
fn csv_missing_text_column_is_rejected() {
    let csv = "id,status\r\nsome-id,open\r\n";
    let target = tempfile::tempdir().unwrap();
    let store = support::open(target.path());
    let error = store.preview_import(csv.as_bytes()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidImport);
}

#[test]
fn csv_idless_rows_dedupe_by_text_and_created_at_but_not_by_text_alone() {
    let with_created_at = "text,created_at\r\nalpha,2026-01-01T00:00:00Z\r\n";
    let target = tempfile::tempdir().unwrap();
    let mut store = support::open(target.path());

    let first = store.apply_import(with_created_at.as_bytes()).unwrap();
    assert_eq!((first.new, first.identical), (1, 0));
    let second = store.apply_import(with_created_at.as_bytes()).unwrap();
    assert_eq!((second.new, second.identical), (0, 1), "same text + created_at dedupes");

    // Neither id nor created_at: always new, even for byte-identical rows.
    let text_only = "text\r\nbeta\r\nbeta\r\n";
    let third = store.apply_import(text_only.as_bytes()).unwrap();
    assert_eq!((third.new, third.identical), (2, 0));
    let fourth = store.apply_import(text_only.as_bytes()).unwrap();
    assert_eq!((fourth.new, fourth.identical), (2, 0), "no created_at means no dedupe key at all");
}

// --- Dry run, backups, atomic file writes ---------------------------------

#[test]
fn dry_run_writes_nothing_and_creates_no_backup() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    a.create_note("preview me", None).unwrap();
    let bytes = a.export_bytes(ExportFormat::Json).unwrap();

    let target = tempfile::tempdir().unwrap();
    let store = support::open(target.path());
    let report = store.preview_import(&bytes).unwrap();
    assert_eq!(report.new, 1);
    assert!(!report.applied);
    assert!(report.backup_path.is_none());
    assert_eq!(all_items(&store).len(), 0, "dry run wrote nothing");
    assert_eq!(store.change_revision().unwrap(), 0);
    assert!(!target.path().join("backups").exists(), "dry run created no backup directory");
}

#[test]
fn apply_import_creates_a_backup_file_before_writing() {
    let source = tempfile::tempdir().unwrap();
    let mut a = support::open(source.path());
    a.create_note("back me up", None).unwrap();
    let bytes = a.export_bytes(ExportFormat::Json).unwrap();

    let target = tempfile::tempdir().unwrap();
    let mut store = support::open(target.path());
    let report = store.apply_import(&bytes).unwrap();
    let backup_path = report.backup_path.expect("apply_import always backs up first");
    assert!(backup_path.exists());
    // Compare canonicalized paths: the temp dir root may itself be a symlink
    // (e.g. macOS's /var -> /private/var), which `Store::open` resolves but
    // `TempDir::path()` does not.
    assert_eq!(backup_path.parent().unwrap().canonicalize().unwrap(), store.data_dir().join("backups"));
    assert!(backup_path.file_name().unwrap().to_string_lossy().starts_with("pre-import-"));
}

#[test]
fn export_file_is_mode_0600_and_refuses_to_overwrite_without_force() {
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().unwrap();
    let mut store = support::open(source.path());
    store.create_note("exported note", None).unwrap();

    let out_dir = tempfile::tempdir().unwrap();
    let path = out_dir.path().join("export.json");
    let summary = store.export_to_file(&path, ExportFormat::Json, false).unwrap();
    assert_eq!(summary.items, 1);
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);

    let error = store.export_to_file(&path, ExportFormat::Json, false).unwrap_err();
    assert_eq!(error.code(), ErrorCode::FileExists);

    store.create_note("second note", None).unwrap();
    let summary = store.export_to_file(&path, ExportFormat::Json, true).unwrap();
    assert_eq!(summary.items, 2, "--force replaced the file");
}

#[test]
fn export_excludes_notification_intents_and_receipts() {
    let source = tempfile::tempdir().unwrap();
    let mut store = support::open(source.path());
    store.create_reminder("has intents and a receipt", &TimeSpec::In("5m".into()), Some("req-1")).unwrap();

    let bytes = store.export_bytes(ExportFormat::Json).unwrap();
    let document: Value = serde_json::from_slice(&bytes).unwrap();
    let reminder = document["items"][0]["reminder"].as_object().expect("reminder present");
    let mut keys: Vec<&str> = reminder.keys().map(String::as_str).collect();
    keys.sort_unstable();
    let mut expected = [
        "acknowledged_at_ms",
        "created_at_ms",
        "deadline_ms",
        "id",
        "input_kind",
        "input_offset_seconds",
        "state",
        "time_input",
        "updated_at_ms",
    ];
    expected.sort_unstable();
    assert_eq!(keys, expected, "no generation/intent/receipt fields leak into the export");
}

#[test]
fn concurrent_writer_during_export_still_yields_a_consistent_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().to_path_buf();
    {
        let mut seed = support::open(&path);
        for n in 0..20 {
            seed.create_note(&format!("seed {n}"), None).unwrap();
        }
    }

    let reader_path = path.clone();
    let writer = thread::spawn(move || {
        let mut store = support::open(&path);
        for n in 0..150 {
            store.create_note(&format!("writer {n}"), None).unwrap();
        }
    });

    let reader = support::open(&reader_path);
    let mut counts = Vec::new();
    for _ in 0..30 {
        let bytes = reader.export_bytes(ExportFormat::Json).unwrap();
        let document: Value = serde_json::from_slice(&bytes).unwrap();
        let items = document["items"].as_array().unwrap();
        assert!(items.len() >= 20, "never sees fewer than the seeded items");
        counts.push(items.len());
    }
    writer.join().unwrap();

    let last = reader.export_bytes(ExportFormat::Json).unwrap();
    let last_document: Value = serde_json::from_slice(&last).unwrap();
    assert_eq!(last_document["items"].as_array().unwrap().len(), 170);
    assert!(counts.iter().all(|&count| count <= 170));
}
