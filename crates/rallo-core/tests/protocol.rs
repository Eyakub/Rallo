//! 0005 M2 notification protocol: `reminders::protocol`'s `Store` operations,
//! driven with `ManualClock` through the fault-injection list, the scheduling
//! and cancellation status tables, and notification actions.

mod support;

use std::sync::Arc;

use rallo_core::items::model::MutationOptions;
use rallo_core::reminders::{
    ActionOutcome, AttemptToken, BeginOutcome, NATIVE_PENDING_CAPACITY_THRESHOLD, NativeOutcome, NativeRequest,
    NextWork, NotificationAction, NotificationAuthorization, PlatformWork, StaleReason, TimeSpec,
};
use rallo_core::shared::clock::{Clock, ManualClock};
use rallo_core::{Store, StoreOptions};
use uuid::Uuid;

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

/// Every deadline in this file is a whole number of seconds from a
/// whole-second clock start, so a readback trigger never needs rounding:
/// `deadline_ms` already equals the platform's rounded-up trigger instant.
const CLOCK_START_MS: i64 = 1_000_000;

fn expect_schedule_work(work: NextWork) -> (i64, Uuid, Uuid, i64, i64, String) {
    match work {
        NextWork::Work(PlatformWork::Schedule {
            intent_id,
            reminder_id,
            item_id,
            generation,
            deadline_ms,
            identifier,
            ..
        }) => (intent_id, reminder_id, item_id, generation, deadline_ms, identifier),
        other => panic!("expected schedule work, got {other:?}"),
    }
}

fn expect_cancel_work(work: NextWork) -> (i64, Uuid, i64, String) {
    match work {
        NextWork::Work(PlatformWork::Cancel { intent_id, reminder_id, generation, identifier }) => {
            (intent_id, reminder_id, generation, identifier)
        }
        other => panic!("expected cancel work, got {other:?}"),
    }
}

fn expect_idle(work: NextWork) -> Option<i64> {
    match work {
        NextWork::Idle { next_wake_at_ms } => next_wake_at_ms,
        other => panic!("expected Idle, got {other:?}"),
    }
}

fn expect_started(outcome: BeginOutcome) -> AttemptToken {
    match outcome {
        BeginOutcome::Started(token) => token,
        BeginOutcome::Superseded => panic!("expected Started, got Superseded"),
    }
}

fn native_request(
    identifier: impl Into<String>,
    reminder_id: Option<Uuid>,
    generation: Option<i64>,
    trigger_ms: Option<i64>,
) -> NativeRequest {
    NativeRequest { identifier: identifier.into(), reminder_id, generation, trigger_ms }
}

// --- record_native_observations / next_platform_work: crash windows -------

#[test]
fn a_pending_schedule_intent_survives_a_restart_and_is_drained_on_the_next_pass() {
    // SQLite transactions are atomic, so "crash before commit" is a no-op by
    // construction; this exercises "crash after commit": a fresh `Store`
    // handle on the same directory (a restarted process) still finds and
    // drains the durably committed intent.
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("survives a restart", &TimeSpec::In("100s".into()), None).unwrap().item;
    let reminder_id = created.reminder.as_ref().unwrap().id;
    drop(store);

    let mut restarted = open_with_clock(temp.path(), clock);
    let (_, work_reminder_id, _, generation, deadline_ms, identifier) =
        expect_schedule_work(restarted.next_platform_work().unwrap());
    assert_eq!(work_reminder_id, reminder_id);
    assert_eq!(generation, 1);
    assert_eq!(deadline_ms, CLOCK_START_MS + 100_000);
    assert!(identifier.ends_with(&reminder_id.to_string()));
}

#[test]
fn begin_with_no_native_effect_is_re_eligible_before_the_deadline_and_delivery_unconfirmed_after() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("crashed mid-attempt", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();

    let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
    expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());

    // No native effect happened and no `finish` was called (a crashed
    // attempt). Before the deadline it is safely re-eligible.
    let (again_intent_id, ..) = expect_schedule_work(store.next_platform_work().unwrap());
    assert_eq!(again_intent_id, intent_id);
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("pending", "submitting"));

    // The deadline elapses with the attempt still unconfirmed: abandoned,
    // never resubmitted.
    clock.advance(200_000);
    let next_wake = expect_idle(store.next_platform_work().unwrap());
    assert_eq!(next_wake, None);
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("unavailable", "delivery_unconfirmed"));

    // Never re-submitted, even on a later pass.
    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None);
}

#[test]
fn acceptance_evidence_before_finish_marks_applied_with_no_second_schedule_work() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("accepted before finish", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let deadline_ms = CLOCK_START_MS + 100_000;

    let (intent_id, reminder_id, _, generation, _, identifier) =
        expect_schedule_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());

    // The native `add()` succeeded and pending readback lists it, but the
    // process crashes before `finish_platform_attempt` runs.
    let pending = vec![native_request(identifier, Some(reminder_id), Some(generation), Some(deadline_ms))];
    store.record_native_observations(NotificationAuthorization::Authorized, &pending, &[]).unwrap();

    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("scheduled", "accepted"));
    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None, "no second schedule work");

    // The delayed `finish` call for the crashed attempt changes nothing.
    let finished =
        store.finish_platform_attempt(token, NativeOutcome::Accepted { readback_trigger_ms: deadline_ms }).unwrap();
    assert_eq!(finished, rallo_core::reminders::Finished { applied: false, superseded: true, retry_at_ms: None });
}

#[test]
fn a_cancel_attempt_interrupted_mid_flight_is_re_eligible_and_idempotent() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("will be cancelled", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    store.acknowledge(&id, &MutationOptions::default()).unwrap();

    let (intent_id, reminder_id, generation, identifier) = expect_cancel_work(store.next_platform_work().unwrap());
    expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());

    // Crashed before the native `removePendingNotificationRequests` call (or
    // its outcome) was recorded: re-eligible, and re-issuing the same
    // identifier is safe.
    let (again_intent_id, again_reminder_id, again_generation, again_identifier) =
        expect_cancel_work(store.next_platform_work().unwrap());
    assert_eq!(
        (again_intent_id, again_reminder_id, again_generation, again_identifier),
        (intent_id, reminder_id, generation, identifier)
    );

    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    let finished = store.finish_platform_attempt(token, NativeOutcome::Removed).unwrap();
    assert!(finished.applied);
    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None);
}

#[test]
fn delivered_before_bookkeeping_is_recorded_as_delivered_and_never_resubmitted() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created =
        store.create_reminder("delivered before bookkeeping", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();

    let (intent_id, reminder_id, _, generation, _, identifier) =
        expect_schedule_work(store.next_platform_work().unwrap());
    expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());

    // The notification already fired and moved to the delivered list before
    // `finish_platform_attempt` ran.
    let delivered = vec![native_request(identifier, Some(reminder_id), Some(generation), None)];
    store.record_native_observations(NotificationAuthorization::Authorized, &[], &delivered).unwrap();

    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("delivered", "observed_in_notification_center"));
    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None, "never resubmitted");
}

#[test]
fn a_newer_intent_mid_attempt_supersedes_the_old_ones_finish_and_the_newer_generation_is_eventually_applied() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("snoozed mid-attempt", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();

    store.record_native_observations(NotificationAuthorization::Authorized, &[], &[]).unwrap();
    let (old_intent_id, _, _, old_generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
    let old_token = expect_started(store.begin_platform_attempt(old_intent_id, old_generation).unwrap());

    // A newer intent is recorded while the old attempt is in flight.
    let snoozed = store.snooze(&id, "50s", &MutationOptions::default()).unwrap();
    let new_generation = snoozed.item.reminder.as_ref().unwrap().generation;
    assert_eq!(new_generation, old_generation + 1);

    let old_finish =
        store.finish_platform_attempt(old_token, NativeOutcome::Accepted { readback_trigger_ms: 0 }).unwrap();
    assert_eq!(old_finish, rallo_core::reminders::Finished { applied: false, superseded: true, retry_at_ms: None });

    let (new_intent_id, _, _, generation, deadline_ms, _) = expect_schedule_work(store.next_platform_work().unwrap());
    assert_eq!(generation, new_generation);
    let new_token = expect_started(store.begin_platform_attempt(new_intent_id, generation).unwrap());
    let finished =
        store.finish_platform_attempt(new_token, NativeOutcome::Accepted { readback_trigger_ms: deadline_ms }).unwrap();
    assert!(finished.applied);
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("scheduled", "accepted"));
}

#[test]
fn a_never_attempted_elapsed_deadline_abandons_as_unattempted() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("never attempted", &TimeSpec::In("10s".into()), None).unwrap().item;
    let id = created.item.id.to_string();

    clock.advance(20_000);
    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None);
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("unavailable", "deadline_elapsed_unattempted"));
}

#[test]
fn an_elapsed_deadline_after_a_failed_attempt_abandons_as_retrying() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("failed then elapsed", &TimeSpec::In("10s".into()), None).unwrap().item;
    let id = created.item.id.to_string();

    let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    store.finish_platform_attempt(token, NativeOutcome::NotConfirmed).unwrap();

    clock.advance(20_000);
    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None);
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("unavailable", "deadline_elapsed_retrying"));
}

// --- backoff, permission, capacity -----------------------------------------

#[test]
fn backoff_follows_1_5_30_60_seconds_capped_and_next_platform_work_respects_the_timer() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    store.create_reminder("backoff", &TimeSpec::In("1000s".into()), None).unwrap();

    for delay_ms in [1_000, 5_000, 30_000, 60_000, 60_000] {
        let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
        let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
        let finished = store
            .finish_platform_attempt(token, NativeOutcome::TransientFailure { code: "internal_error".into() })
            .unwrap();
        let expected_retry_at = clock.now_ms() + delay_ms;
        assert_eq!(
            finished,
            rallo_core::reminders::Finished { applied: false, superseded: false, retry_at_ms: Some(expected_retry_at) }
        );
        assert_eq!(expect_idle(store.next_platform_work().unwrap()), Some(expected_retry_at));
        clock.advance(delay_ms);
    }
    // The last backoff has now elapsed: eligible again.
    expect_schedule_work(store.next_platform_work().unwrap());
}

#[test]
fn permission_denied_blocks_schedule_work_with_no_timer_and_resumes_on_authorization_change() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.record_native_observations(NotificationAuthorization::Denied, &[], &[]).unwrap();
    let created = store.create_reminder("perm denied", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();

    let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    let finished = store.finish_platform_attempt(token, NativeOutcome::PermissionDenied).unwrap();
    assert_eq!(finished, rallo_core::reminders::Finished { applied: false, superseded: false, retry_at_ms: None });

    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None, "no timer while denied");
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("unavailable", "permission_denied"));

    store.record_native_observations(NotificationAuthorization::Authorized, &[], &[]).unwrap();
    let (resumed_intent_id, ..) = expect_schedule_work(store.next_platform_work().unwrap());
    assert_eq!(resumed_intent_id, intent_id);
}

#[test]
fn native_capacity_gate_blocks_scheduling_until_the_observed_count_drops() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let prefix = store.notification_prefix();
    let created = store.create_reminder("capacity gated", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();

    let saturating: Vec<NativeRequest> = (0..NATIVE_PENDING_CAPACITY_THRESHOLD)
        .map(|n| native_request(format!("{prefix}filler-{n}"), None, None, None))
        .collect();
    store.record_native_observations(NotificationAuthorization::Authorized, &saturating, &[]).unwrap();

    assert_eq!(expect_idle(store.next_platform_work().unwrap()), None);
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("pending", "native_capacity"));

    store.record_native_observations(NotificationAuthorization::Authorized, &[], &[]).unwrap();
    expect_schedule_work(store.next_platform_work().unwrap());
}

#[test]
fn missing_from_readback_reopens_an_applied_schedule_with_backoff() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("vanished from readback", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let deadline_ms = CLOCK_START_MS + 100_000;

    let (intent_id, reminder_id, _, generation, _, identifier) =
        expect_schedule_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    store.finish_platform_attempt(token, NativeOutcome::Accepted { readback_trigger_ms: deadline_ms }).unwrap();
    let _ = identifier;

    // The deadline is still comfortably future, but the next pass finds it
    // neither pending nor delivered: silently lost.
    store.record_native_observations(NotificationAuthorization::Authorized, &[], &[]).unwrap();
    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("pending", "retrying"));

    let expected_retry_at = clock.now_ms() + 1_000; // attempt_count is 1: first backoff step.
    assert_eq!(expect_idle(store.next_platform_work().unwrap()), Some(expected_retry_at));
    clock.advance(1_000);
    let (reopened_intent_id, reopened_reminder_id, ..) = expect_schedule_work(store.next_platform_work().unwrap());
    assert_eq!((reopened_intent_id, reopened_reminder_id), (intent_id, reminder_id));
}

#[test]
fn a_trigger_outside_the_acceptance_window_is_a_mismatch_and_retries() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("wrong trigger", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let deadline_ms = CLOCK_START_MS + 100_000;

    let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    let finished = store
        .finish_platform_attempt(token, NativeOutcome::Accepted { readback_trigger_ms: deadline_ms + 5_000 })
        .unwrap();
    assert!(!finished.applied && !finished.superseded);
    assert_eq!(finished.retry_at_ms, Some(clock.now_ms() + 1_000));

    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("pending", "retrying"));
}

#[test]
fn a_stale_token_changes_nothing() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_reminder("stale token", &TimeSpec::In("100s".into()), None).unwrap();

    let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
    let first_token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    // A second `begin` on the same intent (e.g. two racing drainers, or a
    // resumed crashed attempt) invalidates the first token.
    let second_token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    assert_ne!(first_token.attempt, second_token.attempt);

    let stale_finish = store.finish_platform_attempt(first_token, NativeOutcome::Removed).unwrap();
    assert_eq!(stale_finish, rallo_core::reminders::Finished { applied: false, superseded: true, retry_at_ms: None });

    let fresh_finish = store.finish_platform_attempt(second_token, NativeOutcome::Removed).unwrap();
    assert!(fresh_finish.applied);
}

#[test]
fn begin_platform_attempt_on_an_unknown_or_superseded_intent_is_superseded() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("will be rescheduled", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());

    store.reschedule(&id, &TimeSpec::In("200s".into()), &MutationOptions::default()).unwrap();

    assert_eq!(store.begin_platform_attempt(intent_id, generation).unwrap(), BeginOutcome::Superseded);
    assert_eq!(store.begin_platform_attempt(999_999, 1).unwrap(), BeginOutcome::Superseded);
}

// --- cleanup plan and scoping -----------------------------------------------

#[test]
fn cleanup_plan_removes_orphans_and_disabled_reminders_pending_and_delivered() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let prefix = store.notification_prefix();
    let opts = MutationOptions::default();

    let enabled = store.create_reminder("stays enabled", &TimeSpec::In("100s".into()), None).unwrap().item;
    let enabled_reminder = enabled.reminder.as_ref().unwrap();
    let (enabled_id, enabled_gen) = (enabled_reminder.id, enabled_reminder.generation);

    let disabled = store.create_reminder("gets acknowledged", &TimeSpec::In("100s".into()), None).unwrap().item;
    let disabled_reminder_id = disabled.reminder.as_ref().unwrap().id;
    store.acknowledge(&disabled.item.id.to_string(), &opts).unwrap();
    let disabled_view = store.get_item(&disabled.item.id.to_string()).unwrap();
    let disabled_gen = disabled_view.reminder.as_ref().unwrap().generation;

    let unknown_id = Uuid::new_v4();

    let pending = vec![
        native_request(format!("{prefix}{enabled_id}"), Some(enabled_id), Some(enabled_gen), Some(0)),
        native_request(
            format!("{prefix}{disabled_reminder_id}"),
            Some(disabled_reminder_id),
            Some(disabled_gen),
            Some(0),
        ),
        native_request(format!("{prefix}{unknown_id}"), Some(unknown_id), Some(1), Some(0)),
        native_request(format!("{prefix}not-a-uuid"), None, None, None),
    ];
    let delivered = vec![
        native_request(format!("{prefix}{enabled_id}"), Some(enabled_id), Some(enabled_gen), None),
        native_request(format!("{prefix}{disabled_reminder_id}"), Some(disabled_reminder_id), Some(disabled_gen), None),
        native_request(format!("{prefix}{unknown_id}"), Some(unknown_id), Some(1), None),
    ];

    let plan = store.record_native_observations(NotificationAuthorization::Authorized, &pending, &delivered).unwrap();

    assert!(
        !plan.remove_pending.contains(&format!("{prefix}{enabled_id}")),
        "an enabled reminder's pending request stays"
    );
    assert!(
        plan.remove_pending.contains(&format!("{prefix}{disabled_reminder_id}")),
        "a disabled reminder's pending request is removed"
    );
    assert!(
        plan.remove_pending.contains(&format!("{prefix}{unknown_id}")),
        "an unknown reminder's pending request is removed"
    );
    assert!(
        plan.remove_pending.contains(&format!("{prefix}not-a-uuid")),
        "an unparsable identifier in our prefix is removed"
    );

    assert!(
        !plan.remove_delivered.contains(&format!("{prefix}{enabled_id}")),
        "an enabled reminder's delivered request stays"
    );
    assert!(
        plan.remove_delivered.contains(&format!("{prefix}{disabled_reminder_id}")),
        "a disabled reminder's delivered request is removed"
    );
    assert!(
        !plan.remove_delivered.contains(&format!("{prefix}{unknown_id}")),
        "an unknown reminder's delivered request is left alone"
    );
}

#[test]
fn requests_from_another_scope_are_never_recorded_or_cleaned_up() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let our_prefix = store.notification_prefix();
    assert!(our_prefix.starts_with("rallo.reminder."));

    let created = store.create_reminder("isolated by scope", &TimeSpec::In("100s".into()), None).unwrap().item;
    let reminder = created.reminder.as_ref().unwrap();
    let deadline_ms = reminder.deadline_ms;

    // Same identifier suffix, but a different data directory's scope.
    let foreign_identifier = format!("rallo.reminder.deadbeefdeadbeef.{}", reminder.id);
    let pending = vec![native_request(
        foreign_identifier.clone(),
        Some(reminder.id),
        Some(reminder.generation),
        Some(deadline_ms),
    )];
    let delivered =
        vec![native_request(foreign_identifier.clone(), Some(reminder.id), Some(reminder.generation), None)];

    let plan = store.record_native_observations(NotificationAuthorization::Authorized, &pending, &delivered).unwrap();
    assert!(plan.remove_pending.is_empty());
    assert!(plan.remove_delivered.is_empty());

    // Never recorded as evidence: still fresh, never attempted.
    let status = store.scheduling_status(&store.get_item(&created.item.id.to_string()).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason, status.observed_at_ms), ("pending", "awaiting_app", None));
    expect_schedule_work(store.next_platform_work().unwrap());
}

// --- notification actions ---------------------------------------------------

#[test]
fn done_action_completes_the_item_and_disables_the_reminder() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("tap done", &TimeSpec::In("100s".into()), None).unwrap().item;
    let reminder = created.reminder.as_ref().unwrap();
    let (reminder_id, generation) = (reminder.id, reminder.generation);

    match store.apply_notification_action(reminder_id, generation, NotificationAction::Done).unwrap() {
        ActionOutcome::Applied(view) => {
            assert_eq!(view.item.status, rallo_core::items::ItemStatus::Done);
            assert!(!view.reminder.as_ref().unwrap().enabled);
        }
        other => panic!("expected Applied, got {other:?}"),
    }
}

#[test]
fn snooze_action_moves_the_deadline_ten_minutes_out() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(CLOCK_START_MS));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let created = store.create_reminder("tap snooze", &TimeSpec::In("100s".into()), None).unwrap().item;
    let reminder = created.reminder.as_ref().unwrap();
    let (reminder_id, generation) = (reminder.id, reminder.generation);

    match store.apply_notification_action(reminder_id, generation, NotificationAction::Snooze10m).unwrap() {
        ActionOutcome::Applied(view) => {
            let reminder = view.reminder.as_ref().unwrap();
            assert!(reminder.enabled);
            assert_eq!(reminder.deadline_ms, CLOCK_START_MS + 10 * 60 * 1_000);
            assert_eq!(reminder.generation, generation + 1);
        }
        other => panic!("expected Applied, got {other:?}"),
    }
}

#[test]
fn a_stale_generation_reports_changed_with_the_current_item() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("changed underneath", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let reminder = created.reminder.as_ref().unwrap();
    let (reminder_id, stale_generation) = (reminder.id, reminder.generation);

    store.snooze(&id, "5s", &MutationOptions::default()).unwrap();

    match store.apply_notification_action(reminder_id, stale_generation, NotificationAction::Done).unwrap() {
        ActionOutcome::Stale { item: Some(view), reason: StaleReason::Changed } => {
            assert_eq!(view.item.id.to_string(), id);
            assert_eq!(view.item.status, rallo_core::items::ItemStatus::Open, "the stale action never applied");
        }
        other => panic!("expected Stale/Changed, got {other:?}"),
    }
}

#[test]
fn a_deleted_item_reports_deleted_with_the_current_item() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("deleted underneath", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let reminder = created.reminder.as_ref().unwrap();
    let (reminder_id, generation) = (reminder.id, reminder.generation);

    store.delete(&id, &MutationOptions::default()).unwrap();

    match store.apply_notification_action(reminder_id, generation, NotificationAction::Snooze10m).unwrap() {
        ActionOutcome::Stale { item: Some(view), reason: StaleReason::Deleted } => {
            assert!(view.item.deleted_at_ms.is_some());
        }
        other => panic!("expected Stale/Deleted, got {other:?}"),
    }
}

#[test]
fn an_unknown_reminder_id_reports_missing_with_no_item() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());

    match store.apply_notification_action(Uuid::new_v4(), 1, NotificationAction::Done).unwrap() {
        ActionOutcome::Stale { item: None, reason: StaleReason::Missing } => {}
        other => panic!("expected Stale/Missing, got {other:?}"),
    }
}

// --- cancellation status -----------------------------------------------------

#[test]
fn cancellation_status_is_retrying_after_a_failed_cancel_attempt() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("cancel retries", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    store.acknowledge(&id, &MutationOptions::default()).unwrap();

    let (intent_id, _, generation, _) = expect_cancel_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    store.finish_platform_attempt(token, NativeOutcome::TransientFailure { code: "internal_error".into() }).unwrap();

    let status = store.cancellation_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("pending", "retrying"));
}

// --- authorization-dependent applied rows -----------------------------------

#[test]
fn applied_with_not_determined_authorization_reports_permission_not_requested() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = open_with_clock(temp.path(), Arc::new(ManualClock::new(CLOCK_START_MS)));
    let created = store.create_reminder("never asked", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let deadline_ms = created.reminder.as_ref().unwrap().deadline_ms;

    let (intent_id, _, _, generation, _, _) = expect_schedule_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    // Authorization was never observed (default `NotDetermined`).
    store.finish_platform_attempt(token, NativeOutcome::Accepted { readback_trigger_ms: deadline_ms }).unwrap();

    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("scheduled", "permission_not_requested"));
}

#[test]
fn applied_reports_unavailable_permission_denied_once_authorization_turns_denied() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = open_with_clock(temp.path(), Arc::new(ManualClock::new(CLOCK_START_MS)));
    let created = store.create_reminder("revoked afterwards", &TimeSpec::In("100s".into()), None).unwrap().item;
    let id = created.item.id.to_string();
    let deadline_ms = created.reminder.as_ref().unwrap().deadline_ms;

    let (intent_id, reminder_id, _, generation, _, identifier) =
        expect_schedule_work(store.next_platform_work().unwrap());
    let token = expect_started(store.begin_platform_attempt(intent_id, generation).unwrap());
    store.record_native_observations(NotificationAuthorization::Authorized, &[], &[]).unwrap();
    store.finish_platform_attempt(token, NativeOutcome::Accepted { readback_trigger_ms: deadline_ms }).unwrap();

    // The user revokes permission in System Settings; the notification is
    // still sitting in pending readback (the OS does not remove it), only
    // the authorization observation changes.
    let pending = vec![native_request(identifier, Some(reminder_id), Some(generation), Some(deadline_ms))];
    store.record_native_observations(NotificationAuthorization::Denied, &pending, &[]).unwrap();

    let status = store.scheduling_status(&store.get_item(&id).unwrap()).unwrap().unwrap();
    assert_eq!((status.state, status.reason), ("unavailable", "permission_denied"));
}
