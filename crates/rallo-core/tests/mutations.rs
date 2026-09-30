//! 0003 §3 transitions, §7 idempotency, §8 delete-by-text, and §9 revision
//! guards.

mod support;

use std::sync::Arc;
use std::thread;

use rallo_core::items::model::MutationOptions;
use rallo_core::items::query::SearchQuery;
use rallo_core::reminders::ReminderState;
use rallo_core::shared::clock::{Clock, ManualClock};
use rallo_core::shared::errors::ConflictDetail;
use rallo_core::{ErrorCode, Store, StoreOptions};

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

#[test]
fn create_note_is_open_at_revision_one_with_no_reminder() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let outcome = store.create_note("first note", None).unwrap();
    assert!(outcome.changed && !outcome.replayed);
    assert_eq!(outcome.item.item.revision, 1);
    assert!(outcome.item.reminder.is_none());
    assert!(outcome.scheduling.is_none());
    assert!(outcome.cancellation.is_none());
}

#[test]
fn edit_text_is_a_noop_for_identical_text_and_a_change_otherwise() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("hello", None).unwrap().item;

    let same = store.edit_text(&item.item.id.to_string(), "hello", &MutationOptions::default()).unwrap();
    assert!(!same.changed, "identical text is a no-op");
    assert_eq!(same.item.item.revision, 1, "no-ops never bump revision");

    let changed = store.edit_text(&item.item.id.to_string(), "hello there", &MutationOptions::default()).unwrap();
    assert!(changed.changed);
    assert_eq!(changed.item.item.text, "hello there");
    assert_eq!(changed.item.item.revision, 2);
}

#[test]
fn edit_delete_of_a_deleted_item_is_item_deleted_but_reopen_matches() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("gone", None).unwrap().item;
    let id = item.item.id.to_string();
    store.delete(&id, &MutationOptions::default()).unwrap();

    let err = store.edit_text(&id, "changed", &MutationOptions::default()).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ItemDeleted);

    let err = store.complete(&id, &MutationOptions::default()).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ItemDeleted);

    let err = store.reopen(&id, &MutationOptions::default()).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ItemDeleted);

    // delete/restore have no such precondition: deleting an already-deleted
    // item, or nothing yet on a live one, is always a no-op, never an error.
    let noop_delete = store.delete(&id, &MutationOptions::default()).unwrap();
    assert!(!noop_delete.changed);
}

#[test]
fn complete_disables_an_active_reminder_and_reopen_never_reenables_it() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let item = store.create_note("call the dentist", None).unwrap().item;
    let id = item.item.id;
    support::insert_active_reminder(temp.path(), id, 10_000, clock.now_ms());

    let before = store.get_item(&id.to_string()).unwrap();
    assert_eq!(before.reminder.as_ref().unwrap().state(), ReminderState::Active);
    assert!(store.scheduling_status(&before).unwrap().is_some(), "an active reminder is pending scheduling");
    assert!(store.cancellation_status(&before).unwrap().is_none());

    let completed = store.complete(&id.to_string(), &MutationOptions::default()).unwrap();
    assert!(completed.changed);
    let reminder = completed.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.state(), ReminderState::Completed);
    assert_eq!(reminder.generation, 2, "disabling is an intent: generation bumps");
    assert!(store.scheduling_status(&completed.item).unwrap().is_none(), "the old schedule intent was superseded");
    assert!(store.cancellation_status(&completed.item).unwrap().is_some(), "a cancel intent is now pending");

    // Already-done is a no-op: completing again changes nothing further.
    let again = store.complete(&id.to_string(), &MutationOptions::default()).unwrap();
    assert!(!again.changed);

    let reopened = store.reopen(&id.to_string(), &MutationOptions::default()).unwrap();
    assert!(reopened.changed);
    assert_eq!(reopened.item.item.status, rallo_core::items::ItemStatus::Open);
    assert_eq!(reopened.item.reminder.as_ref().unwrap().state(), ReminderState::Completed, "reopen never re-enables");
}

#[test]
fn delete_disables_an_active_reminder_and_restore_keeps_done_status_without_reenabling() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let item = store.create_note("water the plants", None).unwrap().item;
    let id = item.item.id;
    support::insert_active_reminder(temp.path(), id, 10_000, clock.now_ms());

    store.complete(&id.to_string(), &MutationOptions::default()).unwrap();
    let deleted = store.delete(&id.to_string(), &MutationOptions::default()).unwrap();
    assert!(deleted.changed);
    assert_eq!(deleted.item.item.status, rallo_core::items::ItemStatus::Done, "delete keeps status");
    // The reminder was already disabled by `complete`; deleting it again is a
    // no-op for the reminder (still `completed`, not overwritten to `deleted`).
    assert_eq!(deleted.item.reminder.as_ref().unwrap().state(), ReminderState::Completed);

    let restored = store.restore(&id.to_string(), &MutationOptions::default()).unwrap();
    assert!(restored.changed);
    assert!(restored.item.item.deleted_at_ms.is_none());
    assert_eq!(restored.item.item.status, rallo_core::items::ItemStatus::Done, "restore keeps prior done status");
    assert_eq!(restored.item.reminder.as_ref().unwrap().state(), ReminderState::Completed, "restore never re-enables");

    let noop = store.restore(&id.to_string(), &MutationOptions::default()).unwrap();
    assert!(!noop.changed, "restoring an already-live item is a no-op");
}

#[test]
fn edit_text_refreshes_an_active_future_reminder_only_when_previews_are_enabled() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let item = store.create_note("draft the proposal", None).unwrap().item;
    let id = item.item.id;
    support::insert_active_reminder(temp.path(), id, 100_000, clock.now_ms());

    // Previews are off by default: editing text must not touch the reminder.
    let edited = store.edit_text(&id.to_string(), "draft the final proposal", &MutationOptions::default()).unwrap();
    assert_eq!(edited.item.reminder.as_ref().unwrap().generation, 1);

    store.set_preview_text_enabled(true).unwrap();
    let edited_again =
        store.edit_text(&id.to_string(), "draft the final proposal v2", &MutationOptions::default()).unwrap();
    let reminder = edited_again.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.state(), ReminderState::Active, "a refresh intent never disables the reminder");
    assert_eq!(reminder.generation, 2, "previews queue a refresh intent, bumping the generation");
    assert_eq!(reminder.deadline_ms, 100_000, "the deadline itself is untouched");
}

#[test]
fn stale_revision_conflicts_with_current_snapshot_and_mutates_nothing() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("stable text", None).unwrap().item;
    let id = item.item.id.to_string();

    let opts = MutationOptions { request_id: None, if_revision: Some(item.item.revision + 1) };
    let error = store.complete(&id, &opts).unwrap_err();
    assert_eq!(error.code(), ErrorCode::RevisionConflict);
    match error.detail() {
        Some(ConflictDetail::Current { item: current }) => {
            assert_eq!(current.item.revision, 1);
            assert_eq!(current.item.status, rallo_core::items::ItemStatus::Open, "no mutation happened");
        }
        other => panic!("expected Current detail, got {other:?}"),
    }

    let fresh = store.get_item(&id).unwrap();
    assert_eq!(fresh.item.revision, 1, "the stale attempt committed nothing");
}

#[test]
fn already_deleted_with_a_stale_revision_is_still_a_noop_success() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("to be deleted", None).unwrap().item;
    let id = item.item.id.to_string();
    store.delete(&id, &MutationOptions::default()).unwrap();

    // The item is already deleted (the target state), so a wildly wrong
    // if-revision must not surface REVISION_CONFLICT: no-op checks come first.
    let opts = MutationOptions { request_id: None, if_revision: Some(999) };
    let outcome = store.delete(&id, &opts).unwrap();
    assert!(!outcome.changed);
}

#[test]
fn request_id_replay_returns_the_original_result_and_ignores_a_same_text_newcomer() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let original = store.create_note("buy milk", None).unwrap().item;
    let original_id = original.item.id;

    let first_delete = store.delete_by_text("buy milk", Some("del-milk")).unwrap();
    assert_eq!(first_delete.item.item.id, original_id);
    assert!(first_delete.changed && !first_delete.replayed);

    let newcomer = store.create_note("buy milk", None).unwrap().item;
    assert_ne!(newcomer.item.id, original_id);

    let replay = store.delete_by_text("buy milk", Some("del-milk")).unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.item.item.id, original_id, "replay returns the originally deleted item");
    assert!(replay.item.item.deleted_at_ms.is_some());

    let newcomer_now = store.get_item(&newcomer.item.id.to_string()).unwrap();
    assert!(newcomer_now.item.deleted_at_ms.is_none(), "the replay must never delete the newer item");
}

#[test]
fn same_request_id_with_different_inputs_is_a_conflict() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_note("first", Some("shared-id")).unwrap();
    let error = store.create_note("second", Some("shared-id")).unwrap_err();
    assert_eq!(error.code(), ErrorCode::RequestIdConflict);

    // The second (rejected) note must not have been committed.
    let page = store
        .search(SearchQuery { text: "second".into(), exact: true, include_deleted: true, limit: 10, cursor: None })
        .unwrap();
    assert_eq!(page.total_count, 0);
}

#[test]
fn control_characters_round_trip_losslessly() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let text = "line one\tindented\nbell\u{0007}esc\u{001b}[31mnull\u{0000}end";
    let item = store.create_note(text, None).unwrap().item;
    let fetched = store.get_item(&item.item.id.to_string()).unwrap();
    assert_eq!(fetched.item.text, text);
}

#[test]
fn delete_by_text_zero_one_and_many_matches() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());

    let missing = store.delete_by_text("does not exist", None).unwrap_err();
    assert_eq!(missing.code(), ErrorCode::ItemNotFound);

    let only = store.create_note("Review Deployment", None).unwrap().item;
    // Normalisation: outer whitespace/case/NFC differ, internal content matches.
    let deleted = store.delete_by_text("  review deployment  ", None).unwrap();
    assert!(deleted.changed);
    assert_eq!(deleted.item.item.id, only.item.id);

    // A partial match is not an exact match: delete --text must not find it,
    // even though a substring search does.
    store.create_note("Review Deployment Plan", None).unwrap();
    let partial = store.delete_by_text("Review Deployment", None).unwrap_err();
    assert_eq!(partial.code(), ErrorCode::ItemNotFound);
    let found_by_search = store
        .search(SearchQuery {
            text: "Review Deployment".into(),
            exact: false,
            include_deleted: false,
            limit: 10,
            cursor: None,
        })
        .unwrap();
    assert_eq!(found_by_search.total_count, 1);

    // Duplicates: an open and a done item with the same text are ambiguous,
    // never silently resolved to the open one.
    let a = store.create_note("duplicate text", None).unwrap().item;
    let b = store.create_note("duplicate text", None).unwrap().item;
    store.complete(&b.item.id.to_string(), &MutationOptions::default()).unwrap();
    let ambiguous = store.delete_by_text("duplicate text", None).unwrap_err();
    assert_eq!(ambiguous.code(), ErrorCode::AmbiguousItem);
    match ambiguous.detail() {
        Some(ConflictDetail::Candidates { total, candidates }) => {
            assert_eq!(*total, 2);
            let ids: Vec<_> = candidates.iter().map(|c| c.item.id).collect();
            assert!(ids.contains(&a.item.id) && ids.contains(&b.item.id));
        }
        other => panic!("expected Candidates detail, got {other:?}"),
    }

    // Deleted items are excluded from text matching entirely.
    store.delete(&a.item.id.to_string(), &MutationOptions::default()).unwrap();
    let resolved = store.delete_by_text("duplicate text", None).unwrap();
    assert!(resolved.changed);
    assert_eq!(resolved.item.item.id, b.item.id);
}

#[test]
fn concurrent_creates_cannot_make_delete_by_text_delete_more_than_one() {
    let temp = tempfile::tempdir().unwrap();
    support::open(temp.path());
    let dir = temp.path().to_path_buf();

    let creators: Vec<_> = (0..8)
        .map(|_| {
            let dir = dir.clone();
            thread::spawn(move || {
                let mut store = support::open(&dir);
                store.create_note("race condition", None).unwrap();
            })
        })
        .collect();

    let deleter_dir = dir.clone();
    let deleter = thread::spawn(move || {
        let mut store = support::open(&deleter_dir);
        store.delete_by_text("race condition", None)
    });

    for creator in creators {
        creator.join().unwrap();
    }
    let delete_result = deleter.join().unwrap();

    match &delete_result {
        Ok(outcome) => assert!(outcome.changed || !outcome.changed, "either way is fine, see the count check below"),
        Err(error) => assert!(matches!(error.code(), ErrorCode::AmbiguousItem | ErrorCode::ItemNotFound)),
    }

    let store = support::open(&dir);
    let page = store
        .search(SearchQuery {
            text: "race condition".into(),
            exact: true,
            include_deleted: true,
            limit: 200,
            cursor: None,
        })
        .unwrap();
    let deleted_count = page.items.iter().filter(|view| view.item.deleted_at_ms.is_some()).count();
    assert!(deleted_count <= 1, "delete_by_text must never delete more than one item, got {deleted_count}");
}
