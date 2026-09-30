//! Pet reducer (plan §2 "Pet state, in priority order"; 0006): every
//! priority-table row against the pure `decide` function, plus the store's
//! `pet_snapshot` projection and event-counter bookkeeping.

mod support;

use std::sync::Arc;

use rallo_core::items::model::MutationOptions;
use rallo_core::pet::{PetEvent, PetInputs, PetPose, PetSnapshot, decide};
use rallo_core::reminders::{ActionOutcome, NotificationAction, TimeSpec};
use rallo_core::shared::clock::{Clock, ManualClock};
use rallo_core::transfer::ExportFormat;
use rallo_core::{Store, StoreOptions};

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

fn snap(
    open_count: u32,
    due_count: u32,
    next_due_at_ms: Option<i64>,
    completion_seq: i64,
    save_seq: i64,
) -> PetSnapshot {
    PetSnapshot {
        open_count,
        due_count,
        next_due_at_ms,
        completion_seq,
        save_seq,
        agents_waiting: 0,
        agent_waiting_seq: 0,
        agent_done_seq: 0,
    }
}

/// Visible, full-motion, nothing previously seen or due — override the
/// fields a given test cares about with struct-update syntax.
fn inputs(snapshot: PetSnapshot) -> PetInputs {
    PetInputs {
        visible: true,
        reduced_motion: false,
        animations_paused: false,
        snapshot,
        seen_completion_seq: 0,
        seen_save_seq: 0,
        seen_agent_waiting_seq: 0,
        seen_agent_done_seq: 0,
        was_due: false,
    }
}

// --- priority table (pure reducer) ------------------------------------------

#[test]
fn priority_1_hidden_beats_a_due_reminder_and_pending_events() {
    let snapshot = snap(3, 2, Some(500), 10, 10);
    let decision = decide(&PetInputs { visible: false, ..inputs(snapshot) });
    assert_eq!(decision.pose, PetPose::Hidden);
    assert_eq!(decision.event, PetEvent::None);
    assert!(!decision.animate);
    assert!(!decision.ambient);
}

#[test]
fn priority_2_reduced_motion_and_paused_keep_pose_and_event_but_stop_animation() {
    let due = snap(1, 1, None, 0, 0);
    let baseline = decide(&inputs(due));
    assert_eq!(baseline.pose, PetPose::Due);
    assert_eq!(baseline.event, PetEvent::Attention);
    assert!(baseline.animate);

    let reduced = decide(&PetInputs { reduced_motion: true, ..inputs(due) });
    assert_eq!(reduced.pose, baseline.pose);
    assert_eq!(reduced.event, baseline.event);
    assert!(!reduced.animate);
    assert!(!reduced.ambient);

    let paused = decide(&PetInputs { animations_paused: true, ..inputs(due) });
    assert_eq!(paused.pose, baseline.pose);
    assert_eq!(paused.event, baseline.event);
    assert!(!paused.animate);

    let idle = snap(1, 0, None, 0, 0);
    let idle_animated = decide(&inputs(idle));
    assert_eq!(idle_animated.pose, PetPose::Idle);
    assert!(idle_animated.animate);
    assert!(idle_animated.ambient, "ambient motion is allowed while idle and animating");

    let idle_reduced = decide(&PetInputs { reduced_motion: true, ..inputs(idle) });
    assert_eq!(idle_reduced.pose, PetPose::Idle);
    assert!(!idle_reduced.animate);
    assert!(!idle_reduced.ambient, "ambient requires animate");
}

#[test]
fn priority_3_a_due_reminder_shows_attention_only_on_the_rising_edge() {
    let due = snap(1, 1, None, 0, 0);
    let rising = decide(&PetInputs { was_due: false, ..inputs(due) });
    assert_eq!(rising.pose, PetPose::Due);
    assert_eq!(rising.event, PetEvent::Attention);

    let steady = decide(&PetInputs { was_due: true, ..inputs(due) });
    assert_eq!(steady.pose, PetPose::Due);
    assert_eq!(steady.event, PetEvent::None);
}

#[test]
fn priority_3_beats_completion_and_save_events_while_due() {
    let due_with_pending_events = snap(1, 1, None, 5, 5);
    let decision = decide(&PetInputs { was_due: true, ..inputs(due_with_pending_events) });
    assert_eq!(decision.pose, PetPose::Due);
    assert_eq!(decision.event, PetEvent::None, "completions/saves while due never celebrate");
}

#[test]
fn priority_4_a_new_completion_with_nothing_due_celebrates_once() {
    let decision = decide(&inputs(snap(1, 0, None, 1, 0)));
    assert_eq!(decision.pose, PetPose::Idle);
    assert_eq!(decision.event, PetEvent::Celebrate);
}

#[test]
fn priority_4_completion_outranks_a_pending_save() {
    let decision = decide(&inputs(snap(1, 0, None, 1, 1)));
    assert_eq!(decision.event, PetEvent::Celebrate);
}

#[test]
fn priority_5_a_new_save_with_nothing_due_or_newly_completed_shows_acknowledge() {
    let decision = decide(&inputs(snap(1, 0, None, 0, 1)));
    assert_eq!(decision.pose, PetPose::Idle);
    assert_eq!(decision.event, PetEvent::Acknowledge);
}

#[test]
fn priority_6_and_7_steady_pose_is_idle_with_open_items_and_sleeping_without() {
    let idle = decide(&inputs(snap(2, 0, None, 0, 0)));
    assert_eq!(idle.pose, PetPose::Idle);
    assert_eq!(idle.event, PetEvent::None);
    assert!(idle.ambient);

    let sleeping = decide(&inputs(snap(0, 0, None, 0, 0)));
    assert_eq!(sleeping.pose, PetPose::Sleeping);
    assert_eq!(sleeping.event, PetEvent::None);
    assert!(sleeping.ambient);
}

#[test]
fn startup_seeds_seen_counters_so_old_events_never_replay() {
    let snapshot = snap(1, 0, None, 7, 9);
    let decision = decide(&PetInputs { seen_completion_seq: 7, seen_save_seq: 9, ..inputs(snapshot) });
    assert_eq!(decision.event, PetEvent::None);
}

// --- agent attention (0007) --------------------------------------------------

#[test]
fn an_agent_waiting_alone_shows_due_with_attention() {
    let snapshot = PetSnapshot { agents_waiting: 1, agent_waiting_seq: 1, ..snap(1, 0, None, 0, 0) };
    let decision = decide(&inputs(snapshot));
    assert_eq!(decision.pose, PetPose::Due);
    assert_eq!(decision.event, PetEvent::Attention);
}

#[test]
fn a_new_waiting_agent_fires_attention_even_while_already_due_for_a_reminder() {
    let snapshot = PetSnapshot { agents_waiting: 1, agent_waiting_seq: 5, ..snap(1, 1, None, 0, 0) };
    // was_due: true and seen_agent_waiting_seq stale -- the reminder's own
    // rising edge already passed, but a brand new waiting agent still fires.
    let decision = decide(&PetInputs { was_due: true, seen_agent_waiting_seq: 4, ..inputs(snapshot) });
    assert_eq!(decision.pose, PetPose::Due);
    assert_eq!(decision.event, PetEvent::Attention);
}

#[test]
fn an_already_seen_waiting_agent_is_silent_once_due_is_steady() {
    let snapshot = PetSnapshot { agents_waiting: 1, agent_waiting_seq: 5, ..snap(1, 0, None, 0, 0) };
    let decision = decide(&PetInputs { was_due: true, seen_agent_waiting_seq: 5, ..inputs(snapshot) });
    assert_eq!(decision.pose, PetPose::Due);
    assert_eq!(decision.event, PetEvent::None);
}

#[test]
fn a_finished_agent_acknowledges_when_not_due() {
    let snapshot = PetSnapshot { agent_done_seq: 3, ..snap(1, 0, None, 0, 0) };
    let decision = decide(&inputs(snapshot));
    assert_eq!(decision.pose, PetPose::Idle);
    assert_eq!(decision.event, PetEvent::Acknowledge);
}

#[test]
fn a_finished_agent_never_acknowledges_while_due() {
    let snapshot = PetSnapshot { agent_done_seq: 3, ..snap(1, 1, None, 0, 0) };
    let decision = decide(&PetInputs { was_due: true, ..inputs(snapshot) });
    assert_eq!(decision.pose, PetPose::Due);
    assert_eq!(decision.event, PetEvent::None);
}

#[test]
fn celebrate_outranks_a_finished_agent_which_outranks_a_pending_save() {
    let both = PetSnapshot { agent_done_seq: 1, ..snap(1, 0, None, 1, 1) };
    assert_eq!(decide(&inputs(both)).event, PetEvent::Celebrate);

    let agent_and_save = PetSnapshot { agent_done_seq: 1, ..snap(1, 0, None, 0, 1) };
    assert_eq!(decide(&inputs(agent_and_save)).event, PetEvent::Acknowledge);
}

#[test]
fn accessibility_label_appends_waiting_agents() {
    let with_one = PetSnapshot { agents_waiting: 1, ..snap(0, 0, None, 0, 0) };
    assert_eq!(decide(&inputs(with_one)).accessibility_label, "Rallo, no open notes, 1 agent waiting");

    let with_two = PetSnapshot { agents_waiting: 2, ..snap(0, 1, None, 0, 0) };
    assert_eq!(decide(&inputs(with_two)).accessibility_label, "Rallo, 1 reminder due, 2 agents waiting");
}

#[test]
fn accessibility_label_pluralizes_due_reminders_and_open_notes() {
    assert_eq!(decide(&inputs(snap(0, 1, None, 0, 0))).accessibility_label, "Rallo, 1 reminder due");
    assert_eq!(decide(&inputs(snap(0, 2, None, 0, 0))).accessibility_label, "Rallo, 2 reminders due");
    assert_eq!(decide(&inputs(snap(1, 0, None, 0, 0))).accessibility_label, "Rallo, 1 open note");
    assert_eq!(decide(&inputs(snap(3, 0, None, 0, 0))).accessibility_label, "Rallo, 3 open notes");
    assert_eq!(decide(&inputs(snap(0, 0, None, 0, 0))).accessibility_label, "Rallo, no open notes");
}

// --- Store::pet_snapshot -----------------------------------------------------

#[test]
fn pet_snapshot_due_excludes_future_deleted_done_acknowledged_and_cancelled_and_finds_next_due() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(0));
    let mut store = open_with_clock(temp.path(), clock.clone());

    store.create_reminder("overdue1", &TimeSpec::In("1m".into()), None).unwrap(); // deadline 60_000
    store.create_reminder("overdue2", &TimeSpec::In("2m".into()), None).unwrap(); // deadline 120_000
    store.create_reminder("future1", &TimeSpec::In("10m".into()), None).unwrap(); // deadline 600_000
    store.create_reminder("future2", &TimeSpec::In("20m".into()), None).unwrap(); // deadline 1_200_000

    let deleted = store.create_reminder("deleted-one", &TimeSpec::In("1m".into()), None).unwrap().item.item.id;
    store.delete(&deleted.to_string(), &MutationOptions::default()).unwrap();

    let done = store.create_reminder("done-one", &TimeSpec::In("1m".into()), None).unwrap().item.item.id;
    store.complete(&done.to_string(), &MutationOptions::default()).unwrap();

    let acknowledged = store.create_reminder("ack-one", &TimeSpec::In("1m".into()), None).unwrap().item.item.id;
    store.acknowledge(&acknowledged.to_string(), &MutationOptions::default()).unwrap();

    let cancelled = store.create_reminder("cancel-one", &TimeSpec::In("1m".into()), None).unwrap().item.item.id;
    store.cancel_reminder(&cancelled.to_string(), &MutationOptions::default()).unwrap();

    store.create_note("just a note", None).unwrap();

    clock.set(130_000); // past overdue1/overdue2; before future1/future2

    let snapshot = store.pet_snapshot().unwrap();
    assert_eq!(snapshot.due_count, 2, "only the two still-enabled overdue reminders count");
    assert_eq!(snapshot.next_due_at_ms, Some(600_000), "earliest future deadline in the same due-eligible set");
    assert_eq!(snapshot.open_count, 7, "every nondeleted open item (done-one is status done; deleted-one is deleted)");
}

#[test]
fn pet_snapshot_reports_zero_counters_before_any_completion_or_save() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let snapshot = store.pet_snapshot().unwrap();
    assert_eq!((snapshot.open_count, snapshot.due_count, snapshot.next_due_at_ms), (0, 0, None));
    assert_eq!((snapshot.completion_seq, snapshot.save_seq), (0, 0));
    assert_eq!((snapshot.agents_waiting, snapshot.agent_waiting_seq, snapshot.agent_done_seq), (0, 0, 0));
}

#[test]
fn pet_snapshot_counts_fresh_waiting_agents_and_max_seqs_excluding_stale_and_working() {
    use rallo_core::agents::{AgentEvent, AgentKind, AgentState};

    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000_000));
    let mut store = open_with_clock(temp.path(), clock.clone());

    let set_state = |agent, session_id: &str, state| AgentEvent::SetState {
        agent,
        session_id: session_id.to_owned(),
        state,
        cwd: None,
        detail: None,
        app_path: None,
        app_pid: None,
    };

    store.record_agent_event(set_state(AgentKind::Claude, "s1", AgentState::Waiting), 1_000_000).unwrap();
    store.record_agent_event(set_state(AgentKind::Codex, "s2", AgentState::Waiting), 1_000_100).unwrap();
    store.record_agent_event(set_state(AgentKind::Claude, "s3", AgentState::Done), 1_000_200).unwrap();
    // Working rows never count toward agents_waiting.
    store.record_agent_event(set_state(AgentKind::Codex, "s4", AgentState::Working), 1_000_300).unwrap();

    let snapshot = store.pet_snapshot().unwrap();
    assert_eq!(snapshot.agents_waiting, 2);
    assert!(snapshot.agent_waiting_seq > 0);
    assert!(snapshot.agent_done_seq > 0);

    // A stale (>24h) waiting row is excluded from both the count and the max.
    clock.set(1_000_000 + 25 * 60 * 60 * 1000);
    store.record_agent_event(set_state(AgentKind::Codex, "s5", AgentState::Waiting), clock.now_ms()).unwrap();
    let fresh_only = store.pet_snapshot().unwrap();
    assert_eq!(fresh_only.agents_waiting, 1, "the 24h-stale rows were pruned by the write above");
}

// --- event counters -----------------------------------------------------------

#[test]
fn save_seq_increments_on_create_note_and_create_reminder_but_not_on_replay_edit_or_import() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    assert_eq!(store.pet_snapshot().unwrap().save_seq, 0);

    let note = store.create_note("first", Some("note-1")).unwrap().item.item;
    assert_eq!(store.pet_snapshot().unwrap().save_seq, 1);

    store.create_note("first", Some("note-1")).unwrap(); // replay: same request id
    assert_eq!(store.pet_snapshot().unwrap().save_seq, 1, "a replay is not a new save");

    store.create_reminder("remind me", &TimeSpec::In("10m".into()), None).unwrap();
    assert_eq!(store.pet_snapshot().unwrap().save_seq, 2);

    store.edit_text(&note.id.to_string(), "first, edited", &MutationOptions::default()).unwrap();
    assert_eq!(store.pet_snapshot().unwrap().save_seq, 2, "editing text is not a new save");

    // Import inserts records directly through the repository layer, never
    // through create_note/create_reminder, so it never counts as a save.
    let bytes = store.export_bytes(ExportFormat::Json).unwrap();
    let target_dir = tempfile::tempdir().unwrap();
    let mut target = support::open(target_dir.path());
    target.apply_import(&bytes).unwrap();
    assert_eq!(target.pet_snapshot().unwrap().save_seq, 0, "import never counts as a save");
}

#[test]
fn completion_seq_increments_only_for_a_real_transition_to_done() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("finish me", None).unwrap().item.item;
    assert_eq!(store.pet_snapshot().unwrap().completion_seq, 0);

    store.complete(&item.id.to_string(), &MutationOptions::default()).unwrap();
    assert_eq!(store.pet_snapshot().unwrap().completion_seq, 1);

    let no_op = store.complete(&item.id.to_string(), &MutationOptions::default()).unwrap();
    assert!(!no_op.changed);
    assert_eq!(store.pet_snapshot().unwrap().completion_seq, 1, "already-done is a no-op");

    store.reopen(&item.id.to_string(), &MutationOptions::default()).unwrap();
    assert_eq!(store.pet_snapshot().unwrap().completion_seq, 1, "reopen never touches the completion counter");

    // Import never counts as a completion even when it inserts a done item.
    let source_dir = tempfile::tempdir().unwrap();
    let mut source = support::open(source_dir.path());
    let done_note = source.create_note("already done on import", None).unwrap().item.item;
    source.complete(&done_note.id.to_string(), &MutationOptions::default()).unwrap();
    let bytes = source.export_bytes(ExportFormat::Json).unwrap();
    let target_dir = tempfile::tempdir().unwrap();
    let mut target = support::open(target_dir.path());
    target.apply_import(&bytes).unwrap();
    assert_eq!(target.pet_snapshot().unwrap().completion_seq, 0, "import never counts as a completion");
}

#[test]
fn completion_seq_does_not_increment_on_an_idempotent_replay() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("finish me", None).unwrap().item.item;
    let opts = MutationOptions { request_id: Some("done-1".into()), if_revision: None };

    store.complete(&item.id.to_string(), &opts).unwrap();
    assert_eq!(store.pet_snapshot().unwrap().completion_seq, 1);

    let replay = store.complete(&item.id.to_string(), &opts).unwrap();
    assert!(replay.replayed);
    assert_eq!(store.pet_snapshot().unwrap().completion_seq, 1);
}

#[test]
fn a_tapped_done_notification_action_increments_the_completion_counter() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let created = store.create_reminder("tap done", &TimeSpec::In("100s".into()), None).unwrap().item;
    let reminder = created.reminder.as_ref().unwrap();
    let (reminder_id, generation) = (reminder.id, reminder.generation);

    match store.apply_notification_action(reminder_id, generation, NotificationAction::Done).unwrap() {
        ActionOutcome::Applied(_) => {}
        other => panic!("expected Applied, got {other:?}"),
    }
    assert_eq!(store.pet_snapshot().unwrap().completion_seq, 1);
}

#[test]
fn a_burst_of_completions_coalesces_into_a_single_celebration() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let ids: Vec<_> = (0..5).map(|i| store.create_note(&format!("task {i}"), None).unwrap().item.item.id).collect();
    let seen = store.pet_snapshot().unwrap();

    for id in &ids {
        store.complete(&id.to_string(), &MutationOptions::default()).unwrap();
    }
    let after_burst = store.pet_snapshot().unwrap();
    assert_eq!(after_burst.completion_seq, seen.completion_seq + 5, "all five completions were counted");

    // One decide() call after the burst yields exactly one Celebrate, never
    // five queued animations.
    let decision = decide(&PetInputs {
        seen_completion_seq: seen.completion_seq,
        seen_save_seq: after_burst.save_seq,
        ..inputs(after_burst)
    });
    assert_eq!(decision.event, PetEvent::Celebrate);

    // Swift advances its watermark to the current value once it has played
    // that single transient; the same burst never celebrates again.
    let settled = decide(&PetInputs {
        seen_completion_seq: after_burst.completion_seq,
        seen_save_seq: after_burst.save_seq,
        ..inputs(after_burst)
    });
    assert_eq!(settled.event, PetEvent::None);
}

// --- preference ---------------------------------------------------------------

#[test]
fn pet_animations_paused_preference_defaults_to_false_and_only_bumps_revision_on_change() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    assert!(!store.pet_animations_paused().unwrap());
    assert_eq!(store.change_revision().unwrap(), 0);

    assert!(store.set_pet_animations_paused(true).unwrap(), "value changed");
    assert!(store.pet_animations_paused().unwrap());
    assert_eq!(store.change_revision().unwrap(), 1);

    assert!(!store.set_pet_animations_paused(true).unwrap(), "already true: no-op");
    assert_eq!(store.change_revision().unwrap(), 1);

    assert!(store.set_pet_animations_paused(false).unwrap());
    assert!(!store.pet_animations_paused().unwrap());
    assert_eq!(store.change_revision().unwrap(), 2);
}
