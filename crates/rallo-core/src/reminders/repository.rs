use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use uuid::Uuid;

use super::MAX_ACTIVE_REMINDERS;
use super::model::{CancellationStatus, DisabledReason, InputKind, Reminder, SchedulingStatus};
use super::protocol::{self, NotificationAuthorization};
use crate::shared::errors::{ConflictDetail, CoreError, CoreResult, ErrorCode};

const REMINDER_COLUMNS: &str = "id, item_id, deadline_ms, time_input, input_kind, input_offset_seconds, \
                                 enabled, disabled_reason, acknowledged_at_ms, generation, created_at_ms, updated_at_ms";

fn reminder_from_row(row: &Row<'_>) -> rusqlite::Result<Reminder> {
    let id: String = row.get(0)?;
    let item_id: String = row.get(1)?;
    let input_kind: String = row.get(4)?;
    let disabled_reason: Option<String> = row.get(7)?;
    Ok(Reminder {
        id: Uuid::parse_str(&id)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))?,
        item_id: Uuid::parse_str(&item_id)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e)))?,
        deadline_ms: row.get(2)?,
        time_input: row.get(3)?,
        input_kind: InputKind::parse(&input_kind).ok_or_else(|| {
            rusqlite::Error::FromSqlConversionFailure(4, rusqlite::types::Type::Text, "unknown input kind".into())
        })?,
        input_offset_seconds: row.get(5)?,
        enabled: row.get::<_, i64>(6)? != 0,
        disabled_reason: disabled_reason
            .map(|value| {
                DisabledReason::parse(&value).ok_or_else(|| {
                    rusqlite::Error::FromSqlConversionFailure(
                        7,
                        rusqlite::types::Type::Text,
                        "unknown disabled reason".into(),
                    )
                })
            })
            .transpose()?,
        acknowledged_at_ms: row.get(8)?,
        generation: row.get(9)?,
        created_at_ms: row.get(10)?,
        updated_at_ms: row.get(11)?,
    })
}

pub(crate) fn fetch_by_item(conn: &Connection, item_id: Uuid) -> CoreResult<Option<Reminder>> {
    Ok(conn
        .query_row(
            &format!("SELECT {REMINDER_COLUMNS} FROM reminders WHERE item_id = ?1"),
            [item_id.to_string()],
            reminder_from_row,
        )
        .optional()?)
}

/// Looks up a reminder by its own id (0005 `apply_notification_action`),
/// rather than by the item it belongs to.
pub(crate) fn fetch_by_id(conn: &Connection, id: Uuid) -> CoreResult<Option<Reminder>> {
    Ok(conn
        .query_row(
            &format!("SELECT {REMINDER_COLUMNS} FROM reminders WHERE id = ?1"),
            [id.to_string()],
            reminder_from_row,
        )
        .optional()?)
}

/// Kind of `notification_intents` row inserted by an "intent" (0003 §3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum IntentKind {
    Schedule,
    Cancel,
}

impl IntentKind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Schedule => "schedule",
            Self::Cancel => "cancel",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "schedule" => Some(Self::Schedule),
            "cancel" => Some(Self::Cancel),
            _ => None,
        }
    }
}

/// "Intent" per 0003 §3, extended by 0005: bumps the reminder's generation,
/// marks its unresolved (`pending` or `attempting`) intents `superseded` —
/// so an in-flight attempt that finishes after a newer intent was recorded
/// can never mark it applied — and inserts a `pending` intent of `kind` for
/// the new generation. Returns the new generation.
pub(crate) fn record_intent(tx: &Transaction<'_>, reminder_id: Uuid, kind: IntentKind, now_ms: i64) -> CoreResult<i64> {
    let reminder_id = reminder_id.to_string();
    let generation: i64 = tx.query_row(
        "UPDATE reminders SET generation = generation + 1, updated_at_ms = ?2 WHERE id = ?1 RETURNING generation",
        params![reminder_id, now_ms],
        |row| row.get(0),
    )?;
    tx.execute(
        "UPDATE notification_intents SET state = 'superseded', resolved_at_ms = ?2
         WHERE reminder_id = ?1 AND state IN ('pending', 'attempting')",
        params![reminder_id, now_ms],
    )?;
    tx.execute(
        "INSERT INTO notification_intents (reminder_id, generation, kind, state, created_at_ms, attempt_count)
         VALUES (?1, ?2, ?3, 'pending', ?4, 0)",
        params![reminder_id, generation, kind.as_str(), now_ms],
    )?;
    Ok(generation)
}

/// Disables an active reminder for `item_id` with `reason` and records a
/// cancel intent. A no-op if the item has no reminder or it is already
/// disabled (returns `Ok(())` either way; callers check `enabled` beforehand
/// if they need to know whether anything changed). `Acknowledged` also stamps
/// `acknowledged_at_ms`; every other reason leaves it `NULL`.
pub(crate) fn disable_active(
    tx: &Transaction<'_>,
    item_id: Uuid,
    reason: DisabledReason,
    now_ms: i64,
) -> CoreResult<()> {
    let Some(reminder) = fetch_by_item(tx, item_id)? else { return Ok(()) };
    if !reminder.enabled {
        return Ok(());
    }
    let acknowledged_at_ms = matches!(reason, DisabledReason::Acknowledged).then_some(now_ms);
    tx.execute(
        "UPDATE reminders SET enabled = 0, disabled_reason = ?2, acknowledged_at_ms = ?3, updated_at_ms = ?4
         WHERE id = ?1",
        params![reminder.id.to_string(), reason.as_str(), acknowledged_at_ms, now_ms],
    )?;
    record_intent(tx, reminder.id, IntentKind::Cancel, now_ms)?;
    Ok(())
}

/// Enforces `MAX_ACTIVE_REMINDERS` (0003 §4). Callers must run this inside
/// the same write transaction as the enable it guards, before making any
/// change: `BEGIN IMMEDIATE` (`Store::write_tx`) serializes writers, so
/// concurrent creators cannot race past the limit.
pub(crate) fn check_capacity(tx: &Transaction<'_>) -> CoreResult<()> {
    let active: i64 = tx.query_row("SELECT COUNT(*) FROM reminders WHERE enabled = 1", [], |row| row.get(0))?;
    let active = active as u32;
    if active >= MAX_ACTIVE_REMINDERS {
        return Err(CoreError::conflict_detail(
            ErrorCode::ReminderCapacityReached,
            format!("{active} reminders are already active; the limit is {MAX_ACTIVE_REMINDERS}"),
            ConflictDetail::Capacity { limit: MAX_ACTIVE_REMINDERS, active },
        ));
    }
    Ok(())
}

/// Creates a brand-new reminder at generation 1 with a pending `schedule`
/// intent, for an item that has never had one (0003 §3 `remind`, and
/// `reschedule` attaching to a plain note). Unlike `rearm`, there is nothing
/// to supersede yet, so this bypasses `record_intent`.
#[allow(clippy::too_many_arguments)]
pub(crate) fn insert_new(
    tx: &Transaction<'_>,
    item_id: Uuid,
    deadline_ms: i64,
    time_input: &str,
    input_kind: InputKind,
    input_offset_seconds: Option<i32>,
    now_ms: i64,
) -> CoreResult<Uuid> {
    let id = Uuid::new_v4();
    tx.execute(
        "INSERT INTO reminders (id, item_id, deadline_ms, time_input, input_kind, input_offset_seconds,
                                 enabled, generation, created_at_ms, updated_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, 1, ?7, ?7)",
        params![
            id.to_string(),
            item_id.to_string(),
            deadline_ms,
            time_input,
            input_kind.as_str(),
            input_offset_seconds,
            now_ms,
        ],
    )?;
    tx.execute(
        "INSERT INTO notification_intents (reminder_id, generation, kind, state, created_at_ms, attempt_count)
         VALUES (?1, 1, 'schedule', 'pending', ?2, 0)",
        params![id.to_string(), now_ms],
    )?;
    Ok(id)
}

/// Re-arms an existing reminder (active or not) with a new deadline: enables
/// it, clears any acknowledgement/disabled reason, and records a schedule
/// intent — which bumps `generation` and supersedes prior pending intents
/// (0003 §3 `reschedule`/`snooze`).
#[allow(clippy::too_many_arguments)]
pub(crate) fn rearm(
    tx: &Transaction<'_>,
    reminder_id: Uuid,
    deadline_ms: i64,
    time_input: &str,
    input_kind: InputKind,
    input_offset_seconds: Option<i32>,
    now_ms: i64,
) -> CoreResult<()> {
    tx.execute(
        "UPDATE reminders SET deadline_ms = ?2, time_input = ?3, input_kind = ?4, input_offset_seconds = ?5,
                               enabled = 1, disabled_reason = NULL, acknowledged_at_ms = NULL, updated_at_ms = ?6
         WHERE id = ?1",
        params![reminder_id.to_string(), deadline_ms, time_input, input_kind.as_str(), input_offset_seconds, now_ms],
    )?;
    record_intent(tx, reminder_id, IntentKind::Schedule, now_ms)?;
    Ok(())
}

/// Text-edit preview refresh (0003 §3 `edit`): only when a reminder is active
/// and its deadline is still in the future, queue a same-deadline payload
/// refresh. Callers gate this on the `notifications.preview_text` preference.
pub(crate) fn schedule_refresh_if_active(tx: &Transaction<'_>, item_id: Uuid, now_ms: i64) -> CoreResult<()> {
    if let Some(reminder) = fetch_by_item(tx, item_id)?
        && reminder.enabled
        && reminder.deadline_ms > now_ms
    {
        record_intent(tx, reminder.id, IntentKind::Schedule, now_ms)?;
    }
    Ok(())
}

/// The full 0005 status table, computed from the reminder's current
/// generation's `schedule` intent only. `None` if there is none (no
/// reminder, or its current generation recorded a `cancel` intent instead).
pub(crate) fn scheduling_status(
    conn: &Connection,
    reminder: Option<&Reminder>,
) -> CoreResult<Option<SchedulingStatus>> {
    let Some(reminder) = reminder else { return Ok(None) };
    let intent: Option<(String, i64, Option<String>)> = conn
        .query_row(
            "SELECT state, attempt_count, error_code FROM notification_intents
             WHERE reminder_id = ?1 AND generation = ?2 AND kind = 'schedule'",
            params![reminder.id.to_string(), reminder.generation],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let Some((state, attempt_count, error_code)) = intent else { return Ok(None) };

    let observed_at_ms: Option<i64> = conn
        .query_row(
            "SELECT observed_at_ms FROM notification_observations WHERE reminder_id = ?1 AND generation = ?2",
            params![reminder.id.to_string(), reminder.generation],
            |row| row.get(0),
        )
        .optional()?;
    let delivered_observed: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM notification_observations
         WHERE reminder_id = ?1 AND generation = ?2 AND delivered_observed_at_ms IS NOT NULL)",
        params![reminder.id.to_string(), reminder.generation],
        |row| row.get(0),
    )?;

    Ok(Some(match state.as_str() {
        "pending" if error_code.is_none() && attempt_count == 0 => {
            SchedulingStatus { state: "pending", reason: "awaiting_app", observed_at_ms }
        }
        "attempting" => SchedulingStatus { state: "pending", reason: "submitting", observed_at_ms },
        "pending" => match error_code.as_deref() {
            Some("native_capacity") => SchedulingStatus { state: "pending", reason: "native_capacity", observed_at_ms },
            Some("permission_denied") => {
                SchedulingStatus { state: "unavailable", reason: "permission_denied", observed_at_ms }
            }
            _ => SchedulingStatus { state: "pending", reason: "retrying", observed_at_ms },
        },
        "applied" if delivered_observed => {
            SchedulingStatus { state: "delivered", reason: "observed_in_notification_center", observed_at_ms }
        }
        "applied" => match protocol::read_authorization(conn)? {
            NotificationAuthorization::Authorized
            | NotificationAuthorization::Provisional
            | NotificationAuthorization::Ephemeral => {
                SchedulingStatus { state: "scheduled", reason: "accepted", observed_at_ms }
            }
            NotificationAuthorization::NotDetermined => {
                SchedulingStatus { state: "scheduled", reason: "permission_not_requested", observed_at_ms }
            }
            NotificationAuthorization::Denied => {
                SchedulingStatus { state: "unavailable", reason: "permission_denied", observed_at_ms }
            }
        },
        "abandoned" => {
            SchedulingStatus { state: "unavailable", reason: abandon_reason(error_code.as_deref()), observed_at_ms }
        }
        "superseded" => unreachable!(
            "record_intent supersedes only pending/attempting; the current generation's own intent never is"
        ),
        other => unreachable!("notification_intents.state CHECK constraint excludes {other:?}"),
    }))
}

/// The three abandonment codes `next_platform_work` ever writes.
fn abandon_reason(error_code: Option<&str>) -> &'static str {
    match error_code {
        Some("deadline_elapsed_unattempted") => "deadline_elapsed_unattempted",
        Some("deadline_elapsed_retrying") => "deadline_elapsed_retrying",
        Some("delivery_unconfirmed") => "delivery_unconfirmed",
        other => unreachable!(
            "an abandoned schedule intent always carries one of the three abandonment codes, got {other:?}"
        ),
    }
}

/// Cancellation status per 0005: an unresolved cancel intent of the
/// reminder's current generation reports `pending`/`awaiting_app` (never
/// attempted) or `pending`/`retrying`; `None` without one.
pub(crate) fn cancellation_status(
    conn: &Connection,
    reminder: Option<&Reminder>,
) -> CoreResult<Option<CancellationStatus>> {
    let Some(reminder) = reminder else { return Ok(None) };
    let attempt_count: Option<i64> = conn
        .query_row(
            "SELECT attempt_count FROM notification_intents
             WHERE reminder_id = ?1 AND generation = ?2 AND kind = 'cancel' AND state IN ('pending', 'attempting')",
            params![reminder.id.to_string(), reminder.generation],
            |row| row.get(0),
        )
        .optional()?;
    Ok(attempt_count.map(|attempt_count| CancellationStatus {
        state: "pending",
        reason: if attempt_count == 0 { "awaiting_app" } else { "retrying" },
    }))
}
