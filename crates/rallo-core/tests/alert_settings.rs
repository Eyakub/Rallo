//! 0021 §10: the `alerts.settings` preference, and §6: a sound change
//! re-registers pending reminders.

mod support;

use std::sync::Arc;

use rallo_core::preferences::{AlertSettings, AlertSound};
use rallo_core::reminders::ReminderState;
use rallo_core::shared::clock::{Clock, ManualClock};
use rallo_core::{ErrorCode, Store, StoreOptions};

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

fn generation(store: &Store, id: uuid::Uuid) -> i64 {
    store.get_item(&id.to_string()).unwrap().reminder.expect("has a reminder").generation
}

#[test]
fn unset_alert_settings_are_the_spec_defaults() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let expected = AlertSettings {
        summon: true,
        sound: AlertSound::RalloChime,
        nag: true,
        nag_interval_minutes: 2,
        nag_max_rounds: 5,
        glow: false,
        agents: true,
    };
    assert_eq!(store.alert_settings().unwrap(), expected);
    assert_eq!(AlertSettings::default(), expected);
}

#[test]
fn alert_settings_round_trip_and_only_bump_revision_on_change() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let changed = AlertSettings {
        glow: true,
        nag_interval_minutes: 5,
        sound: AlertSound::GentleBell,
        ..AlertSettings::default()
    };
    assert!(store.set_alert_settings(changed.clone()).unwrap());
    let revision = store.change_revision().unwrap();
    assert!(!store.set_alert_settings(changed.clone()).unwrap(), "an identical save is a no-op");
    assert_eq!(store.change_revision().unwrap(), revision, "no-ops never bump the revision");
    assert_eq!(store.alert_settings().unwrap(), changed);
    assert_eq!(support::open(temp.path()).alert_settings().unwrap(), changed, "a second handle sees it");
}

#[test]
fn unreadable_or_partial_alert_settings_fall_back_to_defaults() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let conn = support::raw_connection(temp.path());
    conn.execute(
        "INSERT INTO preferences (key, value, revision, updated_at_ms) VALUES ('alerts.settings', '42', 1, 0)",
        [],
    )
    .unwrap();
    assert_eq!(store.alert_settings().unwrap(), AlertSettings::default());

    // A field this build doesn't know is ignored; a missing one takes its default.
    conn.execute("UPDATE preferences SET value = '{\"glow\":true,\"future\":1}' WHERE key = 'alerts.settings'", [])
        .unwrap();
    assert_eq!(store.alert_settings().unwrap(), AlertSettings { glow: true, ..AlertSettings::default() });
}

#[test]
fn rejected_settings_change_nothing() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let before = store.change_revision().unwrap();
    for bad in [
        AlertSettings { nag_interval_minutes: 0, ..AlertSettings::default() },
        AlertSettings { nag_interval_minutes: 3, ..AlertSettings::default() },
        AlertSettings { nag_max_rounds: 0, ..AlertSettings::default() },
        AlertSettings { nag_max_rounds: 4, ..AlertSettings::default() },
        AlertSettings { nag_max_rounds: 11, ..AlertSettings::default() },
    ] {
        let error = store.set_alert_settings(bad.clone()).unwrap_err();
        assert_eq!(error.code(), ErrorCode::InvalidInput, "{bad:?}");
    }
    assert_eq!(store.change_revision().unwrap(), before);
    assert_eq!(store.alert_settings().unwrap(), AlertSettings::default());
}

#[test]
fn a_sound_change_refreshes_active_future_reminders_only() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let future = store.create_note("future", None).unwrap().item.item.id;
    let elapsed = store.create_note("elapsed", None).unwrap().item.item.id;
    let plain = store.create_note("no reminder", None).unwrap().item.item.id;
    support::insert_active_reminder(temp.path(), future, 100_000, clock.now_ms());
    support::insert_active_reminder(temp.path(), elapsed, 500, clock.now_ms());

    assert!(store.set_alert_settings(AlertSettings { glow: true, ..AlertSettings::default() }).unwrap());
    assert_eq!(generation(&store, future), 1, "only a sound change touches pending reminders");

    let bamboo = AlertSettings { glow: true, sound: AlertSound::BambooKnock, ..AlertSettings::default() };
    assert!(store.set_alert_settings(bamboo).unwrap());
    let reminder = store.get_item(&future.to_string()).unwrap().reminder.unwrap();
    assert_eq!(reminder.generation, 2, "the pending banner is re-registered with the new sound");
    assert_eq!(reminder.deadline_ms, 100_000, "same deadline");
    assert_eq!(reminder.state(), ReminderState::Active);
    assert_eq!(generation(&store, elapsed), 1, "an elapsed deadline is never re-submitted");
    assert!(store.get_item(&plain.to_string()).unwrap().reminder.is_none());
}
