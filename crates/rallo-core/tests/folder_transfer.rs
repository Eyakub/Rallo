//! 0019 §8: export version 3 (folders, `folder_id`, the CSV `folder` column)
//! and the import rules for folders; versions 1 and 2 still import.

mod support;

use rallo_core::folders::{DeleteNotes, FolderSelector};
use rallo_core::items::{ListFilter, ListQuery};
use rallo_core::shared::errors::ConflictDetail;
use rallo_core::transfer::ExportFormat;
use rallo_core::{ErrorCode, Store};
use serde_json::{Value, json};
use uuid::Uuid;

fn named(name: &str) -> FolderSelector {
    FolderSelector::named(name)
}

fn export_json(store: &Store) -> Value {
    serde_json::from_slice(&store.export_bytes(ExportFormat::Json).unwrap()).unwrap()
}

fn bytes(document: &Value) -> Vec<u8> {
    serde_json::to_vec(document).unwrap()
}

fn folder_names(store: &Store) -> Vec<String> {
    store.folders().unwrap().into_iter().filter_map(|entry| entry.folder.map(|folder| folder.name)).collect()
}

fn folder_of(store: &Store, id: Uuid) -> Option<String> {
    store.get_item(&id.to_string()).unwrap().folder.map(|folder| folder.name)
}

fn live_count(store: &Store) -> u64 {
    store.list(ListQuery { filter: ListFilter::All, limit: 1, cursor: None }).unwrap().total_count
}

/// A source store with "Work" holding "work note", Notes holding "loose note",
/// and an empty folder "Empty".
struct Source {
    _dir: tempfile::TempDir,
    store: Store,
    work_note: Uuid,
    loose_note: Uuid,
}

fn source() -> Source {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    store.create_folder("Work", None).unwrap();
    store.create_folder("Empty", None).unwrap();
    let work_note = store.create_note_in("work note", &[], &named("Work"), None).unwrap().item.item.id;
    let loose_note = store.create_note("loose note", None).unwrap().item.item.id;
    Source { _dir: dir, store, work_note, loose_note }
}

#[test]
fn export_writes_version_three_with_folders_and_each_notes_folder_id() {
    let source = source();
    let document = export_json(&source.store);
    assert_eq!(document["version"], 3);
    let folders = document["folders"].as_array().unwrap();
    assert_eq!(folders.iter().map(|folder| folder["name"].as_str().unwrap()).collect::<Vec<_>>(), ["Empty", "Work"]);
    let work = folders.iter().find(|folder| folder["name"] == "Work").unwrap();
    for key in ["id", "name", "created_at_ms", "updated_at_ms"] {
        assert!(work.get(key).is_some(), "folder has {key}");
    }
    let items = document["items"].as_array().unwrap();
    let item = |text: &str| items.iter().find(|item| item["text"] == text).unwrap();
    assert_eq!(item("work note")["folder_id"], work["id"]);
    assert!(item("loose note")["folder_id"].is_null(), "Notes is null, not absent");
}

#[test]
fn the_zip_documents_version_is_three_too() {
    let source = source();
    let dir = tempfile::tempdir().unwrap();
    source.store.export_to_dir(dir.path()).unwrap();
    let document: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("rallo-export.json")).unwrap()).unwrap();
    assert_eq!(document["version"], 3);
    assert_eq!(document["folders"].as_array().unwrap().len(), 2);

    let target_dir = tempfile::tempdir().unwrap();
    let mut target = support::open(target_dir.path());
    let report = target.apply_import_dir(dir.path()).unwrap();
    assert_eq!((report.new, report.new_folders), (2, 2));
    assert_eq!(folder_of(&target, source.work_note).as_deref(), Some("Work"));
}

#[test]
fn json_round_trip_recreates_folders_with_their_ids_and_files_the_notes() {
    let source = source();
    let work = source
        .store
        .folders()
        .unwrap()
        .into_iter()
        .filter_map(|entry| entry.folder)
        .find(|f| f.name == "Work")
        .unwrap();
    let document = bytes(&export_json(&source.store));

    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    let revision = target.change_revision().unwrap();
    let preview = target.preview_import(&document).unwrap();
    assert_eq!((preview.new, preview.new_folders, preview.applied), (2, 2, false));
    assert!(folder_names(&target).is_empty(), "a dry run creates no folder");
    assert_eq!(target.change_revision().unwrap(), revision);

    let report = target.apply_import(&document).unwrap();
    assert_eq!((report.new, report.identical, report.new_folders), (2, 0, 2));
    assert_eq!(folder_names(&target), ["Empty", "Work"], "an empty folder travels too");
    let imported =
        target.folders().unwrap().into_iter().filter_map(|entry| entry.folder).find(|f| f.name == "Work").unwrap();
    assert_eq!(imported.id, work.id, "rule 3: created with the imported id");
    assert_eq!(imported.created_at_ms, work.created_at_ms);
    assert_eq!(imported.revision, 1);
    assert_eq!(folder_of(&target, source.work_note).as_deref(), Some("Work"));
    assert_eq!(folder_of(&target, source.loose_note), None);

    let again = target.apply_import(&document).unwrap();
    assert_eq!((again.new, again.identical, again.new_folders), (0, 2, 0), "re-importing is all identical");
}

#[test]
fn rule_one_the_same_folder_id_is_used_and_a_different_name_is_kept_with_a_warning() {
    let source = source();
    let document = bytes(&export_json(&source.store));
    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    target.apply_import(&document).unwrap();
    target.rename_folder(&named("Work"), "Projects", None).unwrap();

    let report = target.apply_import(&document).unwrap();
    assert_eq!((report.new, report.identical, report.new_folders), (0, 2, 0));
    assert_eq!(report.warnings.len(), 1, "{:?}", report.warnings);
    assert!(
        report.warnings[0].contains("Work") && report.warnings[0].contains("Projects"),
        "names both: {:?}",
        report.warnings
    );
    assert_eq!(folder_names(&target), ["Empty", "Projects"], "the existing name stays");
    assert_eq!(folder_of(&target, source.work_note).as_deref(), Some("Projects"));
}

#[test]
fn rule_two_a_folder_with_the_same_name_key_is_used_for_the_imported_id() {
    let source = source();
    let document = bytes(&export_json(&source.store));
    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    let theirs = target.create_folder("WORK", None).unwrap().folder;

    let report = target.apply_import(&document).unwrap();
    assert_eq!((report.new, report.new_folders), (2, 1), "only Empty is new");
    assert!(report.warnings.is_empty());
    assert_eq!(folder_names(&target), ["Empty", "WORK"]);
    let view = target.get_item(&source.work_note.to_string()).unwrap();
    assert_eq!(view.folder.unwrap().id, theirs.id, "the note joins the existing folder");
}

#[test]
fn an_existing_note_that_differs_only_by_folder_is_a_conflict_and_nothing_is_written() {
    let source = source();
    let document = bytes(&export_json(&source.store));
    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    target.apply_import(&document).unwrap();
    // Only the folder changes: the note keeps its text, status and timestamps, so a conflict can only be the folder.
    support::raw_connection(dir.path())
        .execute("UPDATE items SET folder_id = NULL WHERE id = ?1", [source.work_note.to_string()])
        .unwrap();
    target.delete_folder(&named("Empty"), None, None).unwrap();

    let revision = target.change_revision().unwrap();
    let error = target.apply_import(&document).unwrap_err();
    assert_eq!(error.code(), ErrorCode::ImportConflict);
    match error.detail() {
        Some(ConflictDetail::ImportConflicts { total, conflicts }) => {
            assert_eq!(*total, 1);
            assert_eq!(conflicts[0].id, Some(source.work_note));
        }
        other => panic!("expected import conflicts, got {other:?}"),
    }
    assert_eq!(
        target.preview_import(&document).unwrap_err().code(),
        ErrorCode::ImportConflict,
        "a dry run says the same"
    );
    assert_eq!(target.change_revision().unwrap(), revision, "nothing written");
    assert_eq!(folder_names(&target), ["Work"], "the deleted Empty folder was not recreated");
    assert_eq!(folder_of(&target, source.work_note), None);
}

#[test]
fn versions_one_and_two_still_import_every_note_into_notes() {
    let source = source();
    let current = export_json(&source.store);
    for version in [1, 2] {
        let mut old = current.clone();
        old["version"] = json!(version);
        old.as_object_mut().unwrap().remove("folders");
        for item in old["items"].as_array_mut().unwrap() {
            item.as_object_mut().unwrap().remove("folder_id");
        }
        let dir = tempfile::tempdir().unwrap();
        let mut target = support::open(dir.path());
        let report = target.apply_import(&bytes(&old)).unwrap();
        assert_eq!((report.new, report.new_folders), (2, 0), "version {version}");
        assert!(folder_names(&target).is_empty());
        assert_eq!(folder_of(&target, source.work_note), None, "version {version}: every note is in Notes");
    }
}

#[test]
fn an_old_file_never_compares_folders() {
    // A note filed after a version-2 file was written differs in nothing the
    // file carries. (`move` bumps updated_at, so file it with a raw statement.)
    let source = source();
    let mut old = export_json(&source.store);
    old["version"] = json!(2);
    old.as_object_mut().unwrap().remove("folders");
    for item in old["items"].as_array_mut().unwrap() {
        item.as_object_mut().unwrap().remove("folder_id");
    }
    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    target.apply_import(&bytes(&old)).unwrap();
    target.create_folder("Work", None).unwrap();
    let raw = support::raw_connection(dir.path());
    raw.execute(
        "UPDATE items SET folder_id = (SELECT id FROM folders WHERE name = 'Work') WHERE id = ?1",
        [source.work_note.to_string()],
    )
    .unwrap();
    let report = target.apply_import(&bytes(&old)).unwrap();
    assert_eq!((report.new, report.identical), (0, 2), "identical: an old file says nothing about folders");
    assert_eq!(folder_of(&target, source.work_note).as_deref(), Some("Work"), "and the folder is left alone");
}

#[test]
fn bad_folder_data_is_invalid_import_and_writes_nothing() {
    let source = source();
    let base = export_json(&source.store);
    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    let revision = target.change_revision().unwrap();

    let mut case = |mutate: &dyn Fn(&mut Value)| {
        let mut document = base.clone();
        mutate(&mut document);
        let error = target.apply_import(&bytes(&document)).unwrap_err();
        assert_eq!(error.code(), ErrorCode::InvalidImport, "{document}");
        assert!(!error.to_string().contains("work note"), "messages never carry note text");
        assert!(folder_names(&target).is_empty() && live_count(&target) == 0, "nothing committed for: {document}");
    };
    case(&|doc| doc["items"][0]["folder_id"] = json!(Uuid::new_v4().to_string())); // not in `folders`
    case(&|doc| doc["items"][0]["folder_id"] = json!("not-a-uuid"));
    case(&|doc| doc["folders"][0]["id"] = json!("not-a-uuid"));
    case(&|doc| doc["folders"][0]["name"] = json!("Notes"));
    case(&|doc| doc["folders"][0]["id"] = json!(Uuid::nil().to_string())); // the importer's own placeholder
    case(&|doc| doc["folders"][0]["name"] = json!(""));
    case(&|doc| doc["folders"][0]["name"] = json!("a".repeat(51)));
    case(&|doc| doc["folders"][0]["name"] = json!("two\nlines"));
    case(&|doc| {
        let first = doc["folders"][0].clone();
        doc["folders"] = json!([first.clone(), first]); // duplicate id
    });
    assert_eq!(target.change_revision().unwrap(), revision);

    let mut newer = base.clone();
    newer["version"] = json!(4);
    let error = target.apply_import(&bytes(&newer)).unwrap_err();
    assert_eq!(error.code(), ErrorCode::IncompatibleSchema, "a document newer than this build reads");
}

// --- CSV (0019 §8) ----------------------------------------------------------

#[test]
fn csv_export_ends_with_a_folder_column_holding_the_name() {
    let source = source();
    let csv = String::from_utf8(source.store.export_bytes(ExportFormat::Csv).unwrap()).unwrap();
    let mut lines = csv.trim_start_matches('\u{feff}').split("\r\n");
    assert_eq!(lines.next().unwrap(), "id,text,status,created_at,completed_at,reminder_at,reminder_state,folder");
    let rows: Vec<&str> = lines.filter(|line| !line.is_empty()).collect();
    assert!(rows.iter().any(|row| row.contains("work note") && row.ends_with(",Work")), "{rows:?}");
    assert!(
        rows.iter().any(|row| row.contains("loose note") && row.ends_with(",")),
        "Notes is an empty cell: {rows:?}"
    );
}

#[test]
fn csv_import_creates_a_missing_folder_by_name_and_reuses_an_existing_one_by_key() {
    let source = source();
    let csv = source.store.export_bytes(ExportFormat::Csv).unwrap();

    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    let preview = target.preview_import(&csv).unwrap();
    assert_eq!((preview.new, preview.new_folders), (2, 1), "only Work: CSV can't carry an empty folder");
    assert!(folder_names(&target).is_empty());
    let report = target.apply_import(&csv).unwrap();
    assert_eq!((report.new, report.new_folders), (2, 1));
    assert_eq!(folder_names(&target), ["Work"]);
    assert_eq!(folder_of(&target, source.work_note).as_deref(), Some("Work"));
    assert_eq!(folder_of(&target, source.loose_note), None);

    let other = tempfile::tempdir().unwrap();
    let mut target = support::open(other.path());
    target.create_folder("WORK", None).unwrap();
    let report = target.apply_import(&csv).unwrap();
    assert_eq!(report.new_folders, 0, "the name matches an existing folder's key");
    assert_eq!(folder_names(&target), ["WORK"]);
    assert_eq!(folder_of(&target, source.work_note).as_deref(), Some("WORK"));
}

#[test]
fn csv_without_the_column_imports_to_notes_and_the_name_notes_means_no_folder() {
    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    let old = "id,text,status\r\n,an older export,open\r\n";
    let report = target.apply_import(old.as_bytes()).unwrap();
    assert_eq!((report.new, report.new_folders), (1, 0));
    assert!(report.warnings.is_empty(), "folder is a known column now");

    let notes = "text,folder\r\nfiled nowhere,notes\r\nalso nowhere,\r\n";
    let report = target.apply_import(notes.as_bytes()).unwrap();
    assert_eq!((report.new, report.new_folders), (2, 0));
    assert!(folder_names(&target).is_empty());
    assert_eq!(target.folders().unwrap()[0].open_count, 3);

    let header_case = "TEXT,Folder\r\nshouting header,Work\r\n";
    assert_eq!(target.apply_import(header_case.as_bytes()).unwrap().new_folders, 1);

    for bad in ["x,\"two\nlines\"", &format!("x,{}", "a".repeat(51))] {
        let error = target.apply_import(format!("text,folder\r\n{bad}\r\n").as_bytes()).unwrap_err();
        assert_eq!(error.code(), ErrorCode::InvalidImport, "{bad:?}");
    }
}

#[test]
fn a_csv_row_with_an_id_that_differs_only_by_folder_is_a_conflict() {
    let source = source();
    let csv = source.store.export_bytes(ExportFormat::Csv).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    target.apply_import(&csv).unwrap();
    assert_eq!(target.apply_import(&csv).unwrap().identical, 2, "unchanged: identical");

    // The notes keep their timestamps; only the folder changes.
    support::raw_connection(dir.path())
        .execute("UPDATE items SET folder_id = NULL WHERE id = ?1", [source.work_note.to_string()])
        .unwrap();
    let error = target.apply_import(&csv).unwrap_err();
    assert_eq!(error.code(), ErrorCode::ImportConflict);
}

#[test]
fn two_folders_in_one_file_with_the_same_name_key_become_one() {
    let source = source();
    let mut document = export_json(&source.store);
    let twin = Uuid::new_v4();
    document["folders"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "id": twin, "name": "WORK", "created_at_ms": 1, "updated_at_ms": 1 }));
    // The loose note says "WORK" (found by text: same-millisecond notes export in id order).
    let loose = document["items"].as_array_mut().unwrap().iter_mut().find(|item| item["text"] == "loose note").unwrap();
    loose["folder_id"] = json!(twin);

    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    let report = target.apply_import(&bytes(&document)).unwrap();
    assert_eq!(report.new_folders, 2, "Empty and one Work, not two");
    assert_eq!(folder_names(&target), ["Empty", "Work"]);
    assert_eq!(folder_of(&target, source.work_note).as_deref(), Some("Work"));
    assert_eq!(folder_of(&target, source.loose_note).as_deref(), Some("Work"));
}

#[test]
fn csv_folder_names_get_the_same_formula_guard_as_note_text() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    for name in ["=HYPERLINK(\"x\")", "-archive", "@home", "+1"] {
        store.create_folder(name, None).unwrap();
        store.create_note_in(&format!("in {name}"), &[], &named(name), None).unwrap();
    }
    let csv = store.export_bytes(ExportFormat::Csv).unwrap();
    let text = String::from_utf8(csv.clone()).unwrap();
    for guarded in ["'=HYPERLINK", "'-archive", "'@home", "'+1"] {
        assert!(text.contains(guarded), "{guarded} is guarded: {text}");
    }

    let other = tempfile::tempdir().unwrap();
    let mut target = support::open(other.path());
    let report = target.apply_import(&csv).unwrap();
    assert_eq!((report.new, report.new_folders), (4, 4));
    assert_eq!(folder_names(&target), ["+1", "-archive", "=HYPERLINK(\"x\")", "@home"], "the guard is stripped again");
}

#[test]
fn a_csv_folder_is_only_created_for_rows_that_are_new() {
    let source = source();
    let csv = String::from_utf8(source.store.export_bytes(ExportFormat::Csv).unwrap()).unwrap();
    let created = csv.lines().find(|line| line.contains("work note")).unwrap().split(',').nth(3).unwrap().to_owned();
    let idless = format!("text,created_at,folder\r\nwork note,{created},Work\r\n");

    let dir = tempfile::tempdir().unwrap();
    let mut target = support::open(dir.path());
    target.apply_import(csv.as_bytes()).unwrap();
    target.delete_folder(&named("Work"), Some(DeleteNotes::Keep), None).unwrap();

    // The row is the note already here (same text and creation time): identical, so Work stays deleted.
    let preview = target.preview_import(idless.as_bytes()).unwrap();
    assert_eq!((preview.new, preview.identical, preview.new_folders), (0, 1, 0));
    target.apply_import(idless.as_bytes()).unwrap();
    assert!(folder_names(&target).is_empty());

    // A genuinely new row does create it.
    let fresh = "text,folder\r\na new row,Work\r\n";
    assert_eq!(target.apply_import(fresh.as_bytes()).unwrap().new_folders, 1);
}
