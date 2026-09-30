//! 0003 §3 `remind`/`reschedule`/`snooze`/`acknowledge`/`cancel-reminder`,
//! §4 capacity, §5 time input, and §7 idempotency for reminder mutations
//! (M1 part B).

mod support;

use std::sync::Arc;
use std::thread;

use rallo_core::items::model::MutationOptions;
use rallo_core::items::query::SearchQuery;
use rallo_core::reminders::{
    CancellationStatus, InputKind, MAX_ACTIVE_REMINDERS, ReminderState, SchedulingStatus, TimeSpec,
};
use rallo_core::shared::clock::ManualClock;
use rallo_core::shared::errors::ConflictDetail;
use rallo_core::{ErrorCode, Store, StoreOptions};
use uuid::Uuid;

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

/// Creates `count` reminders with a harmless 10-minute deadline, returning
/// their item ids.
fn fill_active_reminders(store: &mut Store, count: u32, label: &str) -> Vec<Uuid> {
    (0..count)
        .map(|i| {
            store.create_reminder(&format!("{label} {i}"), &TimeSpec::In("10m".into()), None).unwrap().item.item.id
        })
        .collect()
}

#[test]
fn relative_grammar_accepts_valid_forms_computes_deadline_from_the_clock_and_rejects_invalid_ones() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock);

    let cases = [
        ("20m", 1_000 + 20 * 60_000),
        ("1h30m", 1_000 + 90 * 60_000),
        ("2d", 1_000 + 2 * 86_400_000),
        ("45s", 1_000 + 45_000),
    ];
    for (raw, expected_deadline_ms) in cases {
        let outcome = store.create_reminder(&format!("note {raw}"), &TimeSpec::In(raw.into()), None).unwrap();
        let reminder = outcome.item.reminder.as_ref().unwrap();
        assert_eq!(reminder.deadline_ms, expected_deadline_ms, "wrong deadline for {raw:?}");
        assert_eq!(reminder.time_input, raw);
        assert_eq!(reminder.input_kind, InputKind::Relative);
    }

    for bad in ["0m", "m", "1m1m", "30m1h", "1H", "1.5h", "-5m", "", "99999999999999d"] {
        let err = store.create_reminder(&format!("bad {bad}"), &TimeSpec::In(bad.into()), None).unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidTime, "expected INVALID_TIME for {bad:?}");
    }

    // None of the rejected attempts created an item.
    let page = store
        .search(SearchQuery { text: "bad ".into(), exact: false, include_deleted: true, limit: 200, cursor: None })
        .unwrap();
    assert_eq!(page.total_count, 0);
}

#[test]
fn absolute_requires_explicit_offset_and_a_future_deadline_within_range() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000)); // 1970-01-01T00:00:01.000Z
    let mut store = open_with_clock(temp.path(), clock);

    let zulu = store.create_reminder("zulu", &TimeSpec::At("1970-01-01T00:00:02Z".into()), None).unwrap();
    let reminder = zulu.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.deadline_ms, 2_000);
    assert_eq!(reminder.input_kind, InputKind::Absolute);
    assert_eq!(reminder.input_offset_seconds, Some(0));

    let offset = store.create_reminder("offset", &TimeSpec::At("1970-01-01T02:00:02+02:00".into()), None).unwrap();
    let reminder = offset.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.deadline_ms, 2_000, "the same UTC instant regardless of the input's offset");
    assert_eq!(reminder.input_offset_seconds, Some(7_200));

    for bad in [
        "1970-01-01T00:00:02",      // unzoned
        "1970-01-01T00:00:00Z",     // in the past
        "1970-01-01T00:00:01Z",     // exactly now
        "10000-01-01T00:00:00Z",    // year beyond RFC 3339's 4-digit range
        "9999-12-31T23:59:59.001Z", // one millisecond beyond the max deadline
    ] {
        let err = store.create_reminder("bad", &TimeSpec::At(bad.into()), None).unwrap_err();
        assert_eq!(err.code(), ErrorCode::InvalidTime, "expected INVALID_TIME for {bad:?}");
    }
}

#[test]
fn relative_deadline_beyond_year_9999_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let max_deadline_ms = time::macros::datetime!(9999-12-31 23:59:59 UTC).unix_timestamp() * 1_000;
    let clock = Arc::new(ManualClock::new(max_deadline_ms));
    let mut store = open_with_clock(temp.path(), clock);

    let err = store.create_reminder("too far", &TimeSpec::In("1s".into()), None).unwrap_err();
    assert_eq!(err.code(), ErrorCode::InvalidTime);
}

#[test]
fn retried_create_reminder_replays_the_original_deadline_and_never_duplicates() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());

    let first = store.create_reminder("remind me", &TimeSpec::In("20m".into()), Some("req-1")).unwrap();
    let original_deadline = first.item.reminder.as_ref().unwrap().deadline_ms;
    assert_eq!(original_deadline, 1_000 + 20 * 60_000);

    clock.advance(60 * 60_000); // an hour later: recomputing "20m" would give a different deadline
    let replay = store.create_reminder("remind me", &TimeSpec::In("20m".into()), Some("req-1")).unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.item.item.id, first.item.item.id);
    assert_eq!(replay.item.reminder.as_ref().unwrap().deadline_ms, original_deadline);

    let conn = support::raw_connection(temp.path());
    let item_count: i64 = conn.query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0)).unwrap();
    let reminder_count: i64 = conn.query_row("SELECT COUNT(*) FROM reminders", [], |row| row.get(0)).unwrap();
    assert_eq!(item_count, 1, "the replay must not create a second item");
    assert_eq!(reminder_count, 1, "the replay must not create a second reminder");

    let conflict = store.create_reminder("remind me", &TimeSpec::In("30m".into()), Some("req-1")).unwrap_err();
    assert_eq!(conflict.code(), ErrorCode::RequestIdConflict);
}

#[test]
fn retried_snooze_replays_the_original_deadline_and_records_no_second_intent() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("snoozeable", &TimeSpec::In("10m".into()), None).unwrap();
    let id = created.item.item.id.to_string();

    let opts = MutationOptions { request_id: Some("snooze-1".into()), if_revision: None };
    let first = store.snooze(&id, "5m", &opts).unwrap();
    let original_deadline = first.item.reminder.as_ref().unwrap().deadline_ms;
    let original_generation = first.item.reminder.as_ref().unwrap().generation;

    clock.advance(60 * 60_000);
    let replay = store.snooze(&id, "5m", &opts).unwrap();
    assert!(replay.replayed);
    let reminder = replay.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.deadline_ms, original_deadline, "must not move the deadline again");
    assert_eq!(reminder.generation, original_generation, "no second intent was recorded");
}

#[test]
fn capacity_allows_32_active_and_rejects_the_33rd_with_nothing_committed() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    fill_active_reminders(&mut store, MAX_ACTIVE_REMINDERS, "slot");

    let err = store.create_reminder("one too many", &TimeSpec::In("10m".into()), None).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ReminderCapacityReached);
    match err.detail() {
        Some(ConflictDetail::Capacity { limit, active }) => {
            assert_eq!(*limit, MAX_ACTIVE_REMINDERS);
            assert_eq!(*active, MAX_ACTIVE_REMINDERS);
        }
        other => panic!("expected Capacity detail, got {other:?}"),
    }

    let page = store
        .search(SearchQuery {
            text: "one too many".into(),
            exact: true,
            include_deleted: true,
            limit: 10,
            cursor: None,
        })
        .unwrap();
    assert_eq!(page.total_count, 0, "the rejected attempt committed nothing");
}

#[test]
fn acknowledged_cancelled_completed_and_deleted_reminders_free_capacity_slots() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let ids = fill_active_reminders(&mut store, MAX_ACTIVE_REMINDERS, "slot");
    let opts = MutationOptions::default();

    store.acknowledge(&ids[0].to_string(), &opts).unwrap();
    store.cancel_reminder(&ids[1].to_string(), &opts).unwrap();
    store.complete(&ids[2].to_string(), &opts).unwrap();
    store.delete(&ids[3].to_string(), &opts).unwrap();

    // Four slots freed: four new reminders now fit, but a fifth does not.
    for i in 0..4 {
        let outcome = store.create_reminder(&format!("replacement {i}"), &TimeSpec::In("10m".into()), None).unwrap();
        assert!(outcome.changed);
    }
    let err = store.create_reminder("over again", &TimeSpec::In("10m".into()), None).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ReminderCapacityReached);
}

#[test]
fn reenabling_a_disabled_reminder_needs_a_free_slot() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let ids = fill_active_reminders(&mut store, MAX_ACTIVE_REMINDERS, "slot");
    let opts = MutationOptions::default();

    store.acknowledge(&ids[0].to_string(), &opts).unwrap();
    // Refill the slot `acknowledge` just freed, so the capacity is 32/32 again
    // with `ids[0]`'s reminder sitting disabled.
    store.create_reminder("filler", &TimeSpec::In("10m".into()), None).unwrap();

    let err = store.snooze(&ids[0].to_string(), "5m", &opts).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ReminderCapacityReached);
    let err = store.reschedule(&ids[0].to_string(), &TimeSpec::In("5m".into()), &opts).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ReminderCapacityReached);

    let still = store.get_item(&ids[0].to_string()).unwrap();
    assert_eq!(still.reminder.as_ref().unwrap().state(), ReminderState::Acknowledged, "nothing was re-enabled");
}

#[test]
fn snoozing_or_rescheduling_an_already_active_reminder_at_capacity_succeeds() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let ids = fill_active_reminders(&mut store, MAX_ACTIVE_REMINDERS, "slot");
    let opts = MutationOptions::default();

    let snoozed = store.snooze(&ids[0].to_string(), "20m", &opts).unwrap();
    assert!(snoozed.changed);
    assert!(snoozed.item.reminder.as_ref().unwrap().enabled);

    let rescheduled = store.reschedule(&ids[1].to_string(), &TimeSpec::In("25m".into()), &opts).unwrap();
    assert!(rescheduled.changed);
    assert!(rescheduled.item.reminder.as_ref().unwrap().enabled);
}

#[test]
fn concurrent_creators_cannot_exceed_capacity() {
    let temp = tempfile::tempdir().unwrap();
    support::open(temp.path());
    let dir = temp.path().to_path_buf();

    let creators: Vec<_> = (0..8)
        .map(|t| {
            let dir = dir.clone();
            thread::spawn(move || {
                let mut store = support::open(&dir);
                for i in 0..10 {
                    let _ = store.create_reminder(&format!("thread {t} item {i}"), &TimeSpec::In("10m".into()), None);
                }
            })
        })
        .collect();
    for creator in creators {
        creator.join().unwrap();
    }

    let conn = support::raw_connection(&dir);
    let active: i64 = conn.query_row("SELECT COUNT(*) FROM reminders WHERE enabled = 1", [], |row| row.get(0)).unwrap();
    assert!(active as u32 <= MAX_ACTIVE_REMINDERS, "active={active} must never exceed {MAX_ACTIVE_REMINDERS}");
}

#[test]
fn snooze_clears_acknowledgement_and_increments_generation() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock);
    let created = store.create_reminder("ack then snooze", &TimeSpec::In("10m".into()), None).unwrap();
    let id = created.item.item.id.to_string();
    let opts = MutationOptions::default();

    let acknowledged = store.acknowledge(&id, &opts).unwrap();
    let reminder = acknowledged.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.state(), ReminderState::Acknowledged);
    assert!(reminder.acknowledged_at_ms.is_some());
    assert_eq!(reminder.generation, 2);

    let snoozed = store.snooze(&id, "15m", &opts).unwrap();
    let reminder = snoozed.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.state(), ReminderState::Active);
    assert!(reminder.acknowledged_at_ms.is_none(), "snooze clears the acknowledgement");
    assert_eq!(reminder.generation, 3);
}

#[test]
fn reschedule_attaches_a_reminder_to_a_plain_open_note() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock);
    let note = store.create_note("plain note", None).unwrap().item;
    assert!(note.reminder.is_none());

    let opts = MutationOptions::default();
    let rescheduled = store.reschedule(&note.item.id.to_string(), &TimeSpec::In("30m".into()), &opts).unwrap();
    assert!(rescheduled.changed);
    let reminder = rescheduled.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.state(), ReminderState::Active);
    assert_eq!(reminder.generation, 1, "a brand-new reminder starts at generation 1: nothing to supersede");
    assert_eq!(reminder.deadline_ms, 1_000 + 30 * 60_000);
}

#[test]
fn snooze_acknowledge_and_cancel_require_an_existing_reminder() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let note = store.create_note("no reminder yet", None).unwrap().item;
    let id = note.item.id.to_string();
    let opts = MutationOptions::default();

    assert_eq!(store.snooze(&id, "10m", &opts).unwrap_err().code(), ErrorCode::NoReminder);
    assert_eq!(store.acknowledge(&id, &opts).unwrap_err().code(), ErrorCode::NoReminder);
    assert_eq!(store.cancel_reminder(&id, &opts).unwrap_err().code(), ErrorCode::NoReminder);
}

#[test]
fn reschedule_and_snooze_are_rejected_on_done_and_deleted_items() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let opts = MutationOptions::default();

    let done = store.create_note("done note", None).unwrap().item;
    store.complete(&done.item.id.to_string(), &opts).unwrap();
    assert_eq!(
        store.reschedule(&done.item.id.to_string(), &TimeSpec::In("10m".into()), &opts).unwrap_err().code(),
        ErrorCode::ItemNotOpen
    );
    assert_eq!(store.snooze(&done.item.id.to_string(), "10m", &opts).unwrap_err().code(), ErrorCode::ItemNotOpen);

    let deleted = store.create_note("deleted note", None).unwrap().item;
    store.delete(&deleted.item.id.to_string(), &opts).unwrap();
    assert_eq!(
        store.reschedule(&deleted.item.id.to_string(), &TimeSpec::In("10m".into()), &opts).unwrap_err().code(),
        ErrorCode::ItemDeleted
    );
    assert_eq!(store.snooze(&deleted.item.id.to_string(), "10m", &opts).unwrap_err().code(), ErrorCode::ItemDeleted);
}

#[test]
fn reopen_leaves_a_disabled_reminder_disabled_and_a_later_reschedule_needs_capacity() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let opts = MutationOptions::default();

    let created = store.create_reminder("will complete", &TimeSpec::In("10m".into()), None).unwrap();
    let reminder_id = created.item.reminder.as_ref().unwrap().id;
    let id = created.item.item.id.to_string();
    store.complete(&id, &opts).unwrap();
    let reopened = store.reopen(&id, &opts).unwrap();
    assert_eq!(reopened.item.reminder.as_ref().unwrap().state(), ReminderState::Completed, "reopen never re-enables");
    assert_eq!(reopened.item.reminder.as_ref().unwrap().id, reminder_id, "the same reminder row, reused, not new");

    let fillers = fill_active_reminders(&mut store, MAX_ACTIVE_REMINDERS, "filler");
    let err = store.reschedule(&id, &TimeSpec::In("5m".into()), &opts).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ReminderCapacityReached);

    store.acknowledge(&fillers[0].to_string(), &opts).unwrap();
    let rescheduled = store.reschedule(&id, &TimeSpec::In("5m".into()), &opts).unwrap();
    assert!(rescheduled.changed);
    let reminder = rescheduled.item.reminder.as_ref().unwrap();
    assert_eq!(reminder.state(), ReminderState::Active);
    assert_eq!(reminder.id, reminder_id, "still the same reminder row");
}

#[test]
fn restore_leaves_a_disabled_reminder_disabled_and_a_later_reschedule_needs_capacity() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let opts = MutationOptions::default();

    let created = store.create_reminder("will be deleted", &TimeSpec::In("10m".into()), None).unwrap();
    let reminder_id = created.item.reminder.as_ref().unwrap().id;
    let id = created.item.item.id.to_string();
    store.delete(&id, &opts).unwrap();
    let restored = store.restore(&id, &opts).unwrap();
    assert_eq!(restored.item.reminder.as_ref().unwrap().state(), ReminderState::Deleted, "restore never re-enables");
    assert_eq!(restored.item.reminder.as_ref().unwrap().id, reminder_id);

    let fillers = fill_active_reminders(&mut store, MAX_ACTIVE_REMINDERS, "filler");
    let err = store.reschedule(&id, &TimeSpec::In("5m".into()), &opts).unwrap_err();
    assert_eq!(err.code(), ErrorCode::ReminderCapacityReached);

    store.cancel_reminder(&fillers[0].to_string(), &opts).unwrap();
    let rescheduled = store.reschedule(&id, &TimeSpec::In("5m".into()), &opts).unwrap();
    assert!(rescheduled.changed);
    assert_eq!(rescheduled.item.reminder.as_ref().unwrap().state(), ReminderState::Active);
}

#[test]
fn generation_strictly_increases_and_exactly_one_pending_intent_survives_for_the_latest() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock);
    let created = store.create_reminder("gen note", &TimeSpec::In("10m".into()), None).unwrap();
    let item_id = created.item.item.id;
    assert_eq!(created.item.reminder.as_ref().unwrap().generation, 1);
    assert_eq!(created.item.item.revision, 1);

    let opts = MutationOptions::default();
    let after_reschedule = store.reschedule(&item_id.to_string(), &TimeSpec::In("20m".into()), &opts).unwrap();
    assert_eq!(after_reschedule.item.item.revision, 2);
    let after_snooze = store.snooze(&item_id.to_string(), "30m", &opts).unwrap();
    assert_eq!(after_snooze.item.item.revision, 3);
    let after_ack = store.acknowledge(&item_id.to_string(), &opts).unwrap();
    assert_eq!(after_ack.item.item.revision, 4);

    let final_item = store.get_item(&item_id.to_string()).unwrap();
    let reminder = final_item.reminder.unwrap();
    assert_eq!(reminder.generation, 4, "create=1, reschedule=2, snooze=3, acknowledge=4");

    let conn = support::raw_connection(temp.path());
    let pending: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM notification_intents WHERE reminder_id = ?1 AND state = 'pending'",
            [reminder.id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(pending, 1, "exactly one pending intent survives");
    let pending_generation: i64 = conn
        .query_row(
            "SELECT generation FROM notification_intents WHERE reminder_id = ?1 AND state = 'pending'",
            [reminder.id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(pending_generation, reminder.generation, "the surviving pending intent is for the latest generation");
    let superseded: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM notification_intents WHERE reminder_id = ?1 AND state = 'superseded'",
            [reminder.id.to_string()],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(superseded, 3, "the three earlier generations' intents were superseded");
}

#[test]
fn stale_if_revision_conflicts_on_reschedule_and_mutates_nothing() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let note = store.create_note("guarded", None).unwrap().item;
    let id = note.item.id.to_string();

    let opts = MutationOptions { request_id: None, if_revision: Some(note.item.revision + 1) };
    let err = store.reschedule(&id, &TimeSpec::In("10m".into()), &opts).unwrap_err();
    assert_eq!(err.code(), ErrorCode::RevisionConflict);

    let fresh = store.get_item(&id).unwrap();
    assert!(fresh.reminder.is_none(), "the stale attempt committed nothing");
    assert_eq!(fresh.item.revision, 1);
}

#[test]
fn scheduling_is_pending_for_active_reminders_and_cancellation_is_pending_after_acknowledge() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("status check", &TimeSpec::In("10m".into()), None).unwrap();
    assert_eq!(
        created.scheduling,
        Some(SchedulingStatus { state: "pending", reason: "awaiting_app", observed_at_ms: None })
    );
    assert!(created.cancellation.is_none());

    let id = created.item.item.id.to_string();
    let acknowledged = store.acknowledge(&id, &MutationOptions::default()).unwrap();
    assert!(acknowledged.scheduling.is_none(), "the schedule intent was superseded");
    assert_eq!(acknowledged.cancellation, Some(CancellationStatus { state: "pending", reason: "awaiting_app" }));
}
