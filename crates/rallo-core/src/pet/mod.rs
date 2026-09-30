//! Pet reducer (plan §2 "Pet state, in priority order"; 0006).
//!
//! `Store::pet_snapshot` is the only I/O: a cheap, read-only projection of
//! domain state. `decide` is a pure function with no clock or storage access,
//! so the priority table is unit-testable without a database. Swift owns
//! animation timing/rendering and decides when a played transient advances
//! `seen_completion_seq`/`seen_save_seq` (coalescing any further jumps into
//! the next decision); the core only computes what to show right now.

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use crate::shared::errors::CoreResult;
use crate::storage::database::Store;

const COMPLETION_SEQ_KEY: &str = "events.completion_seq";
const SAVE_SEQ_KEY: &str = "events.save_seq";

fn read_metadata_i64(conn: &Connection, key: &str) -> CoreResult<Option<i64>> {
    Ok(conn.query_row("SELECT value FROM metadata WHERE key = ?1", [key], |row| row.get(0)).optional()?)
}

/// Increments (creating at 1 if absent) a monotonic event counter inside the
/// caller's write transaction, so it lands atomically with the change it
/// reports. Never called for a no-op, a replay, or import (those construct
/// rows directly through `repository`, bypassing `items::service` /
/// `reminders::service`).
fn increment_metadata_i64(tx: &Transaction<'_>, key: &str) -> CoreResult<()> {
    tx.execute(
        "INSERT INTO metadata (key, value) VALUES (?1, 1)
         ON CONFLICT (key) DO UPDATE SET value = value + 1",
        params![key],
    )?;
    Ok(())
}

pub(crate) fn increment_completion_seq(tx: &Transaction<'_>) -> CoreResult<()> {
    increment_metadata_i64(tx, COMPLETION_SEQ_KEY)
}

pub(crate) fn increment_save_seq(tx: &Transaction<'_>) -> CoreResult<()> {
    increment_metadata_i64(tx, SAVE_SEQ_KEY)
}

/// Cheap, read-only projection of domain state the reducer needs (plan §2
/// rows 3-7). Counts exclude deleted items throughout; `due_count` and
/// `next_due_at_ms` additionally require the item open and the reminder
/// enabled (which already implies unacknowledged).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PetSnapshot {
    pub open_count: u32,
    pub due_count: u32,
    /// Earliest future deadline among the same due-eligible set, so Swift can
    /// arm one timer instead of polling.
    pub next_due_at_ms: Option<i64>,
    pub completion_seq: i64,
    pub save_seq: i64,
}

impl Store {
    /// Read-only; reuses `items_open_by_created` (open_count) and
    /// `reminders_enabled_deadline` (due_count/next_due_at_ms) — both already
    /// indexed for `list`/`list --due`, so no migration is needed here.
    pub fn pet_snapshot(&self) -> CoreResult<PetSnapshot> {
        let now = self.now_ms();
        let conn = self.conn();
        let open_count: u32 =
            conn.query_row("SELECT COUNT(*) FROM items WHERE deleted_at_ms IS NULL AND status = 'open'", [], |row| {
                row.get(0)
            })?;
        let (due_count, next_due_at_ms): (u32, Option<i64>) = conn.query_row(
            "SELECT COUNT(*) FILTER (WHERE r.deadline_ms <= ?1),
                    MIN(CASE WHEN r.deadline_ms > ?1 THEN r.deadline_ms END)
             FROM items i JOIN reminders r ON r.item_id = i.id
             WHERE i.deleted_at_ms IS NULL AND i.status = 'open' AND r.enabled = 1",
            [now],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let completion_seq = read_metadata_i64(conn, COMPLETION_SEQ_KEY)?.unwrap_or(0);
        let save_seq = read_metadata_i64(conn, SAVE_SEQ_KEY)?.unwrap_or(0);
        Ok(PetSnapshot { open_count, due_count, next_due_at_ms, completion_seq, save_seq })
    }
}

/// Everything `decide` needs: the domain snapshot plus ephemeral UI/session
/// state that only Swift knows (visibility, accessibility settings, and what
/// it has already shown).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PetInputs {
    pub visible: bool,
    pub reduced_motion: bool,
    pub animations_paused: bool,
    pub snapshot: PetSnapshot,
    /// `completion_seq` last acknowledged by a played celebration. Startup
    /// initializes this to the current `completion_seq` so old completions
    /// never replay.
    pub seen_completion_seq: i64,
    /// `save_seq` last acknowledged by a played acknowledgement, same
    /// startup rule.
    pub seen_save_seq: i64,
    /// Whether the previous decision's pose was already `Due`: a completion
    /// or save made while due never celebrates, only the falling edge does.
    pub was_due: bool,
}

/// The steady pose (plan §2's priority rows collapsed to one state).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PetPose {
    Hidden,
    Sleeping,
    Idle,
    Due,
}

/// A one-shot transition to play once, then recompute (plan §2 rows 3-5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PetEvent {
    None,
    Attention,
    Celebrate,
    Acknowledge,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PetDecision {
    pub pose: PetPose,
    pub event: PetEvent,
    /// Whether Swift should animate at all right now (visible, not reduced
    /// motion, not paused). Reduced motion/pause change presentation only —
    /// never `pose` or `event` above.
    pub animate: bool,
    /// Low-frequency idle motion is allowed: animating and steady (`Idle`/`Sleeping`).
    pub ambient: bool,
    pub accessibility_label: String,
}

fn accessibility_label(snapshot: &PetSnapshot) -> String {
    if snapshot.due_count > 0 {
        format!("Rallo, {} reminder{} due", snapshot.due_count, if snapshot.due_count == 1 { "" } else { "s" })
    } else if snapshot.open_count > 0 {
        format!("Rallo, {} open note{}", snapshot.open_count, if snapshot.open_count == 1 { "" } else { "s" })
    } else {
        "Rallo, no open notes".to_owned()
    }
}

/// Pure priority-table reducer (plan §2). No clock or storage access, so
/// every row is a plain unit test.
pub fn decide(inputs: &PetInputs) -> PetDecision {
    let accessibility_label = accessibility_label(&inputs.snapshot);
    if !inputs.visible {
        return PetDecision {
            pose: PetPose::Hidden,
            event: PetEvent::None,
            animate: false,
            ambient: false,
            accessibility_label,
        };
    }

    let snapshot = &inputs.snapshot;
    let (pose, event) = if snapshot.due_count > 0 {
        let event = if inputs.was_due { PetEvent::None } else { PetEvent::Attention };
        (PetPose::Due, event)
    } else {
        let pose = if snapshot.open_count > 0 { PetPose::Idle } else { PetPose::Sleeping };
        let event = if snapshot.completion_seq > inputs.seen_completion_seq {
            PetEvent::Celebrate
        } else if snapshot.save_seq > inputs.seen_save_seq {
            PetEvent::Acknowledge
        } else {
            PetEvent::None
        };
        (pose, event)
    };

    let animate = inputs.visible && !inputs.reduced_motion && !inputs.animations_paused;
    let ambient = animate && matches!(pose, PetPose::Idle | PetPose::Sleeping);

    PetDecision { pose, event, animate, ambient, accessibility_label }
}
