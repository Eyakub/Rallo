//! 0019 §3-§5: folder names, create/rename/delete, `move`, and filing a new
//! note into a folder.

mod support;

use std::sync::Arc;

use rallo_core::folders::{DeleteNotes, FolderSelector, NotesDisposition};
use rallo_core::items::{ItemStatus, ListFilter, ListQuery, MutationOptions};
use rallo_core::reminders::{ReminderState, TimeSpec};
use rallo_core::shared::clock::{Clock, ManualClock};
use rallo_core::{CoreError, ErrorCode, Store, StoreOptions};
use serde_json::json;

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

fn named(name: &str) -> FolderSelector {
    FolderSelector::named(name)
}

fn opts() -> MutationOptions {
    MutationOptions::default()
}

fn folder_names(store: &Store) -> Vec<String> {
    store
        .folders()
        .unwrap()
        .into_iter()
        .map(|entry| entry.folder.map_or_else(|| "Notes".to_owned(), |folder| folder.name))
        .collect()
}

// --- names (0019 §3) -------------------------------------------------------

#[test]
fn folders_list_notes_first_then_alphabetical_with_open_counts_only() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_folder("work", None).unwrap();
    store.create_folder("Archive", None).unwrap();
    store.create_folder("école", None).unwrap();
    // Byte order of the key, not a locale's: "é" sorts after "w" (0019 §3).
    assert_eq!(folder_names(&store), ["Notes", "Archive", "work", "école"]);

    let open = store.create_note_in("open", &[], &named("work"), None).unwrap().item.item;
    let done = store.create_note_in("done", &[], &named("work"), None).unwrap().item.item;
    store.complete(&done.id.to_string(), &opts()).unwrap();
    let gone = store.create_note_in("gone", &[], &named("work"), None).unwrap().item.item;
    store.delete(&gone.id.to_string(), &opts()).unwrap();
    store.create_note("loose", None).unwrap();

    let counts: Vec<u64> = store.folders().unwrap().iter().map(|entry| entry.open_count).collect();
    assert_eq!(counts, [1, 0, 1, 0], "Notes has 1, work has 1 (the done and deleted notes don't count)");
    let notes: Vec<u64> = store.folders().unwrap().iter().map(|entry| entry.note_count).collect();
    assert_eq!(notes, [1, 0, 2, 0], "note_count is open + done: work holds 2, the deleted note isn't held");
    assert_eq!(open.folder_id, store.get_item(&open.id.to_string()).unwrap().folder.map(|f| f.id));
}

#[test]
fn names_are_trimmed_and_limited_to_fifty_characters_without_control_characters() {
    let temp = tempfile::tempdir().unwrap();
    let store = &mut support::open(temp.path());

    assert_eq!(store.create_folder("  Work  ", None).unwrap().folder.name, "Work");
    assert!(store.create_folder(&"a".repeat(50), None).is_ok());
    assert!(store.create_folder(&"ক".repeat(50), None).is_ok(), "50 characters, not 50 bytes");
    for bad in [
        "",
        "   ",
        &"a".repeat(51),
        "two\nlines",
        "tab\there",
        "bell\u{7}",
        "a\u{2028}b",
        "a\u{2029}b",
        "Notes",
        " notes ",
        "NOTES",
    ] {
        let error = store.create_folder(bad, None).unwrap_err();
        assert_eq!(error.code(), ErrorCode::FolderNameInvalid, "{bad:?}");
    }
    assert_eq!(folder_names(store).len(), 4, "only the three good names and Notes exist");
}

#[test]
fn two_folders_cannot_share_a_key_but_a_rename_may_change_only_the_case() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let work = store.create_folder("work", None).unwrap().folder;
    store.create_folder("Home", None).unwrap();

    assert_eq!(store.create_folder("WORK", None).unwrap_err().code(), ErrorCode::FolderExists);
    // "Cafe\u{301}" and "Caf\u{e9}" are one name after NFC.
    store.create_folder("Cafe\u{301}", None).unwrap();
    assert_eq!(store.create_folder("Caf\u{e9}", None).unwrap_err().code(), ErrorCode::FolderExists);

    clock.advance(500);
    let revision_before = store.change_revision().unwrap();
    let renamed = store.rename_folder(&named("work"), "Work", None).unwrap();
    assert!(renamed.changed);
    assert_eq!(renamed.folder.name, "Work");
    assert_eq!(renamed.folder.id, work.id);
    assert_eq!(renamed.folder.revision, 2);
    assert_eq!(renamed.folder.updated_at_ms, 1_500);
    assert!(store.change_revision().unwrap() > revision_before);

    let same = store.rename_folder(&named("WORK"), "Work", None).unwrap();
    assert!(!same.changed, "the same name is a no-op");
    assert_eq!(same.folder.revision, 2);

    assert_eq!(store.rename_folder(&named("Work"), "home", None).unwrap_err().code(), ErrorCode::FolderExists);
    assert_eq!(store.rename_folder(&named("Work"), "Notes", None).unwrap_err().code(), ErrorCode::FolderNameInvalid);
    assert_eq!(store.rename_folder(&named("Notes"), "Mine", None).unwrap_err().code(), ErrorCode::FolderNameInvalid);
    assert_eq!(store.rename_folder(&named("nope"), "Mine", None).unwrap_err().code(), ErrorCode::FolderNotFound);
}

#[test]
fn an_unknown_folder_is_not_found_and_its_message_lists_the_folders() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_folder("Work", None).unwrap();
    store.create_folder("Home", None).unwrap();

    let error = store.create_note_in("typo", &[], &named("Wrok"), None).unwrap_err();
    assert_eq!(error.code(), ErrorCode::FolderNotFound);
    let message = error.to_string();
    assert!(message.contains("Wrok") && message.contains("Home") && message.contains("Work"), "{message}");
    assert!(message.contains("Notes"), "Notes is always one of the folders: {message}");
    assert_eq!(folder_names(&store), ["Notes", "Home", "Work"], "a typo never creates a folder");
    let all = store.list(ListQuery { filter: ListFilter::All, limit: 10, cursor: None }).unwrap();
    assert_eq!(all.total_count, 0, "and the note was not saved");

    let by_id = store.create_note_in("x", &[], &FolderSelector::Id(uuid::Uuid::new_v4()), None).unwrap_err();
    assert_eq!(by_id.code(), ErrorCode::FolderNotFound);
}

// --- filing notes (0019 §5) ------------------------------------------------

#[test]
fn a_new_note_or_reminder_can_start_in_a_folder_and_notes_means_no_folder() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let work = store.create_folder("Work", None).unwrap().folder;

    let note = store.create_note_in("in work", &[], &named("work"), None).unwrap().item;
    assert_eq!(note.folder.as_ref().unwrap().id, work.id);
    assert_eq!(serde_json::to_value(&note).unwrap()["folder"], json!({ "id": work.id, "name": "Work" }));

    let reminder =
        store.create_reminder_in("remind in work", &TimeSpec::In("20m".into()), &[], &named("Work"), None).unwrap();
    assert_eq!(reminder.item.folder.as_ref().unwrap().name, "Work");
    assert!(reminder.item.reminder.is_some());

    let loose = store.create_note_in("loose", &[], &named("NOTES"), None).unwrap().item;
    assert!(loose.folder.is_none());
    assert!(serde_json::to_value(&loose).unwrap()["folder"].is_null());
    assert!(store.create_note("plain", None).unwrap().item.folder.is_none());
}

#[test]
fn move_changes_the_folder_bumps_revision_and_is_a_noop_when_already_there() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let work = store.create_folder("Work", None).unwrap().folder;
    let id = store.create_note("file me", None).unwrap().item.item.id.to_string();

    clock.advance(10);
    let before = store.change_revision().unwrap();
    let moved = store.move_item(&id, &named("work"), &opts()).unwrap();
    assert!(moved.changed);
    assert_eq!(moved.item.folder.as_ref().unwrap().id, work.id);
    assert_eq!(moved.item.item.revision, 2);
    assert_eq!(moved.item.item.updated_at_ms, 1_010);
    assert!(store.change_revision().unwrap() > before);

    let again = store.move_item(&id, &named("Work"), &opts()).unwrap();
    assert!(!again.changed, "already there");
    assert_eq!(again.item.item.revision, 2);
    assert_eq!(store.change_revision().unwrap(), before + 1, "a no-op bumps nothing");

    let back = store.move_item(&id, &FolderSelector::Notes, &opts()).unwrap();
    assert!(back.changed && back.item.folder.is_none());
    assert!(!store.move_item(&id, &named("notes"), &opts()).unwrap().changed);
}

#[test]
fn move_follows_the_mutation_order_receipt_resolve_noop_revision_then_mutate() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_folder("Work", None).unwrap();
    let id = store.create_note("a note", None).unwrap().item.item.id.to_string();

    // A done note can be moved.
    store.complete(&id, &opts()).unwrap();
    assert!(store.move_item(&id, &named("Work"), &opts()).unwrap().changed);

    // Already there wins over a stale revision, like every no-op (0003 §9).
    let stale = MutationOptions { request_id: None, if_revision: Some(1) };
    assert!(!store.move_item(&id, &named("Work"), &stale).unwrap().changed);
    // A real move with a stale revision conflicts and changes nothing.
    let error = store.move_item(&id, &FolderSelector::Notes, &stale).unwrap_err();
    assert_eq!(error.code(), ErrorCode::RevisionConflict);
    assert_eq!(store.get_item(&id).unwrap().folder.unwrap().name, "Work");

    assert_eq!(store.move_item(&id, &named("Nope"), &opts()).unwrap_err().code(), ErrorCode::FolderNotFound);
    assert_eq!(store.move_item("zzzzzzzz", &named("Work"), &opts()).unwrap_err().code(), ErrorCode::ItemNotFound);

    store.delete(&id, &opts()).unwrap();
    assert_eq!(store.move_item(&id, &FolderSelector::Notes, &opts()).unwrap_err().code(), ErrorCode::ItemDeleted);
}

#[test]
fn request_ids_replay_folder_commands_and_collide_on_different_inputs() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());

    let first = store.create_folder("Work", Some("create-1")).unwrap();
    let replay = store.create_folder("Work", Some("create-1")).unwrap();
    assert!(!first.replayed && replay.replayed);
    assert_eq!(replay.folder.id, first.folder.id);
    assert_eq!(folder_names(&store), ["Notes", "Work"], "the retry created nothing");
    let conflict = store.create_folder("Other", Some("create-1")).unwrap_err();
    assert_eq!(conflict.code(), ErrorCode::RequestIdConflict);
    let recased = store.create_folder("WORK", Some("create-1")).unwrap_err();
    assert_eq!(recased.code(), ErrorCode::RequestIdConflict, "0003 §7: the original input, not its key");

    let renamed = store.rename_folder(&named("Work"), "Projects", Some("rename-1")).unwrap();
    let replay = store.rename_folder(&named("Work"), "Projects", Some("rename-1")).unwrap();
    assert!(replay.replayed && replay.folder.revision == renamed.folder.revision, "a replay doesn't rename twice");
    let again = store.create_folder("Work", Some("create-1")).unwrap();
    assert_eq!(again.folder.name, "Projects", "a replay reports the folder as it is now");

    let id = store.create_note("n", None).unwrap().item.item.id.to_string();
    let moved = MutationOptions { request_id: Some("move-1".into()), if_revision: None };
    assert!(store.move_item(&id, &named("Projects"), &moved).unwrap().changed);
    let replay = store.move_item(&id, &named("Projects"), &moved).unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.item.item.revision, 2, "a replay doesn't move twice");

    let deleted = store.delete_folder(&named("Projects"), Some(DeleteNotes::Keep), Some("delete-1")).unwrap();
    let replay = store.delete_folder(&named("Projects"), Some(DeleteNotes::Keep), Some("delete-1")).unwrap();
    assert!(replay.replayed && replay.moved == deleted.moved && replay.moved == 1);
}

// --- delete (0019 §5) ------------------------------------------------------

#[test]
fn deleting_a_folder_that_holds_notes_needs_keep_or_delete_and_says_how_many() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_folder("Work", None).unwrap();
    store.create_note_in("one", &[], &named("Work"), None).unwrap();
    let two = store.create_note_in("two", &[], &named("Work"), None).unwrap().item.item;
    store.complete(&two.id.to_string(), &opts()).unwrap(); // done notes count as held

    let revision = store.change_revision().unwrap();
    let error = store.delete_folder(&named("Work"), None, None).unwrap_err();
    assert_eq!(error.code(), ErrorCode::FolderNotEmpty);
    assert!(matches!(error, CoreError::Conflict { .. }), "0019 §4: a Conflict to the FFI (the CLI maps it to exit 2)");
    assert_eq!(error.to_string(), "Folder \u{201c}Work\u{201d} holds 2 notes: pass --keep-notes or --delete-notes");
    assert_eq!(folder_names(&store), ["Notes", "Work"], "nothing changed");
    assert_eq!(store.change_revision().unwrap(), revision);

    assert_eq!(store.delete_folder(&named("Nope"), None, None).unwrap_err().code(), ErrorCode::FolderNotFound);
    assert_eq!(
        store.delete_folder(&FolderSelector::Notes, None, None).unwrap_err().code(),
        ErrorCode::FolderNameInvalid
    );
}

#[test]
fn an_empty_folder_needs_no_flag_and_a_folder_with_only_deleted_notes_is_empty() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_folder("Empty", None).unwrap();
    let outcome = store.delete_folder(&named("Empty"), None, None).unwrap();
    assert_eq!(outcome.notes, NotesDisposition::None);
    assert_eq!((outcome.moved, outcome.deleted), (0, 0));

    store.create_folder("Old", None).unwrap();
    let note = store.create_note_in("old", &[], &named("Old"), None).unwrap().item.item;
    store.delete(&note.id.to_string(), &opts()).unwrap();
    let outcome = store.delete_folder(&named("Old"), None, None).unwrap();
    assert_eq!(outcome.notes, NotesDisposition::None);
    let restored = store.restore(&note.id.to_string(), &opts()).unwrap().item;
    assert!(restored.folder.is_none(), "the deleted note left the folder with it");
    assert_eq!(folder_names(&store), ["Notes"]);
}

#[test]
fn keep_notes_sends_every_note_open_done_and_deleted_to_notes_in_one_revision_bump() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    store.create_folder("Work", None).unwrap();
    let open = store.create_note_in("open", &[], &named("Work"), None).unwrap().item.item;
    let done = store.create_note_in("done", &[], &named("Work"), None).unwrap().item.item;
    store.complete(&done.id.to_string(), &opts()).unwrap();
    let gone = store.create_note_in("gone", &[], &named("Work"), None).unwrap().item.item;
    store.delete(&gone.id.to_string(), &opts()).unwrap();
    let before: Vec<i64> =
        [&open, &done, &gone].iter().map(|item| store.get_item(&item.id.to_string()).unwrap().item.revision).collect();

    clock.advance(77);
    let revision = store.change_revision().unwrap();
    let outcome = store.delete_folder(&named("work"), Some(DeleteNotes::Keep), None).unwrap();
    assert_eq!(outcome.notes, NotesDisposition::Kept);
    assert_eq!((outcome.moved, outcome.deleted), (2, 0), "counts are the nondeleted notes");
    assert_eq!(store.change_revision().unwrap(), revision + 1, "one bump for the whole delete");
    assert_eq!(folder_names(&store), ["Notes"]);

    for (item, old_revision) in [&open, &done, &gone].into_iter().zip(before) {
        let view = store.get_item(&item.id.to_string()).unwrap();
        assert!(view.folder.is_none(), "{} is in Notes", view.item.text);
        assert_eq!(view.item.revision, old_revision + 1);
        assert_eq!(view.item.updated_at_ms, 1_077);
    }
    assert!(store.get_item(&gone.id.to_string()).unwrap().item.deleted_at_ms.is_some(), "still deleted");
    assert_eq!(store.get_item(&done.id.to_string()).unwrap().item.status, ItemStatus::Done);
    assert_eq!(store.folders().unwrap()[0].open_count, 1, "the open note shows up in Notes");
}

#[test]
fn delete_notes_cancels_reminders_exactly_as_a_single_delete_does() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    store.create_folder("Work", None).unwrap();
    let single = store.create_note("deleted on its own", None).unwrap().item.item;
    let filed = store.create_note_in("deleted with the folder", &[], &named("Work"), None).unwrap().item.item;
    let plain = store.create_note_in("no reminder", &[], &named("Work"), None).unwrap().item.item;
    for id in [single.id, filed.id] {
        support::insert_active_reminder(temp.path(), id, 60_000, clock.now_ms());
    }

    store.delete(&single.id.to_string(), &opts()).unwrap();
    let outcome = store.delete_folder(&named("Work"), Some(DeleteNotes::Delete), None).unwrap();
    assert_eq!(outcome.notes, NotesDisposition::Deleted);
    assert_eq!((outcome.moved, outcome.deleted, outcome.reminders_cancelled), (0, 2, 1));

    let view = store.get_item(&filed.id.to_string()).unwrap();
    let reminder = view.reminder.as_ref().unwrap();
    assert_eq!(reminder.state(), ReminderState::Deleted);
    assert!(store.cancellation_status(&view).unwrap().is_some(), "a cancel intent is pending for the app");

    let raw = support::raw_connection(temp.path());
    let rows = |item: uuid::Uuid| -> Vec<(String, String)> {
        let mut statement = raw
            .prepare(
                "SELECT n.kind, n.state FROM notification_intents n JOIN reminders r ON r.id = n.reminder_id
                 WHERE r.item_id = ?1 ORDER BY n.id",
            )
            .unwrap();
        statement
            .query_map([item.to_string()], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert_eq!(rows(filed.id), rows(single.id), "the same intents, in the same states");
    assert_eq!(
        rows(filed.id),
        [("schedule".to_owned(), "superseded".to_owned()), ("cancel".to_owned(), "pending".to_owned())]
    );
    let disabled = |item: uuid::Uuid| -> (i64, String) {
        raw.query_row("SELECT enabled, disabled_reason FROM reminders WHERE item_id = ?1", [item.to_string()], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap()
    };
    assert_eq!(disabled(filed.id), disabled(single.id));
    assert_eq!(disabled(filed.id), (0, "item_deleted".to_owned()));

    // Every note is soft-deleted and out of the folder; restoring puts it in Notes.
    for id in [filed.id, plain.id] {
        let view = store.get_item(&id.to_string()).unwrap();
        assert!(view.item.deleted_at_ms.is_some() && view.folder.is_none());
    }
    let restored = store.restore(&plain.id.to_string(), &opts()).unwrap().item;
    assert!(restored.folder.is_none());
    assert_eq!(restored.item.status, ItemStatus::Open);
}

#[test]
fn a_restored_note_returns_to_its_folder_or_to_notes_if_that_folder_is_gone() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_folder("Work", None).unwrap();
    let note = store.create_note_in("n", &[], &named("Work"), None).unwrap().item.item;
    let id = note.id.to_string();
    store.delete(&id, &opts()).unwrap();
    assert_eq!(store.get_item(&id).unwrap().folder.unwrap().name, "Work", "a deleted note keeps its folder");
    assert_eq!(store.restore(&id, &opts()).unwrap().item.folder.unwrap().name, "Work");
}

#[test]
fn a_folder_is_found_by_its_key_whatever_the_case_or_unicode_composition() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_folder("Caf\u{e9}", None).unwrap();
    for spelling in ["CAF\u{c9}", "cafe\u{301}", "  Caf\u{e9}  "] {
        let note = store.create_note_in("a note", &[], &named(spelling), None).unwrap().item;
        assert_eq!(note.folder.unwrap().name, "Caf\u{e9}", "{spelling:?}");
    }
    assert_eq!(folder_names(&store), ["Notes", "Caf\u{e9}"]);
}

#[test]
fn a_folder_another_process_deleted_is_folder_not_found_never_a_dangling_note() {
    let temp = tempfile::tempdir().unwrap();
    let mut app = support::open(temp.path());
    let mut cli = support::open(temp.path());
    let work = app.create_folder("Work", None).unwrap().folder;
    let note = app.create_note("n", None).unwrap().item.item.id.to_string();

    // The app still holds Work's id when the CLI deletes the folder.
    cli.delete_folder(&named("Work"), None, None).unwrap();
    let stale = FolderSelector::Id(work.id);
    assert_eq!(app.create_note_in("x", &[], &stale, None).unwrap_err().code(), ErrorCode::FolderNotFound);
    assert_eq!(app.move_item(&note, &stale, &opts()).unwrap_err().code(), ErrorCode::FolderNotFound);
    assert_eq!(app.rename_folder(&stale, "Y", None).unwrap_err().code(), ErrorCode::FolderNotFound);
    assert_eq!(app.delete_folder(&stale, Some(DeleteNotes::Keep), None).unwrap_err().code(), ErrorCode::FolderNotFound);
    let all = app.list(ListQuery { filter: ListFilter::All, limit: 10, cursor: None }).unwrap();
    assert_eq!(all.total_count, 1, "only the note that was already there");
    assert!(app.get_item(&note).unwrap().folder.is_none());
}
