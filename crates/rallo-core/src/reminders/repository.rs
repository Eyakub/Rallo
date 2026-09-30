use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use uuid::Uuid;

use super::model::{CancellationStatus, DisabledReason, InputKind, Reminder, SchedulingStatus};
use crate::shared::errors::CoreResult;

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

/// Kind of `notification_intents` row inserted by an "intent" (0003 §3).
#[derive(Clone, Copy)]
pub(crate) enum IntentKind {
    Schedule,
    Cancel,
}

impl IntentKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Schedule => "schedule",
            Self::Cancel => "cancel",
        }
    }
}

/// "Intent" per 0003 §3: bumps the reminder's generation, marks its `pending`
/// intents `superseded`, and inserts a `pending` intent of `kind` for the new
/// generation. Returns the new generation.
pub(crate) fn record_intent(tx: &Transaction<'_>, reminder_id: Uuid, kind: IntentKind, now_ms: i64) -> CoreResult<i64> {
    let reminder_id = reminder_id.to_string();
    let generation: i64 = tx.query_row(
        "UPDATE reminders SET generation = generation + 1, updated_at_ms = ?2 WHERE id = ?1 RETURNING generation",
        params![reminder_id, now_ms],
        |row| row.get(0),
    )?;
    tx.execute(
        "UPDATE notification_intents SET state = 'superseded', resolved_at_ms = ?2
         WHERE reminder_id = ?1 AND state = 'pending'",
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
/// if they need to know whether anything changed).
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
    tx.execute(
        "UPDATE reminders SET enabled = 0, disabled_reason = ?2, updated_at_ms = ?3 WHERE id = ?1",
        params![reminder.id.to_string(), reason.as_str(), now_ms],
    )?;
    record_intent(tx, reminder.id, IntentKind::Cancel, now_ms)?;
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

/// M1 has nothing draining intents yet, so an active reminder always reports
/// `pending`/`awaiting_app` (0003 §11); computed from the unresolved
/// `schedule` intent that every activation leaves behind.
pub(crate) fn scheduling_status(
    conn: &Connection,
    reminder: Option<&Reminder>,
) -> CoreResult<Option<SchedulingStatus>> {
    let Some(reminder) = reminder else { return Ok(None) };
    let pending: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM notification_intents
         WHERE reminder_id = ?1 AND kind = 'schedule' AND state IN ('pending', 'attempting'))",
        [reminder.id.to_string()],
        |row| row.get(0),
    )?;
    Ok(pending.then_some(SchedulingStatus { state: "pending", reason: "awaiting_app", observed_at_ms: None }))
}

/// An unresolved cancel intent reports `pending`/`awaiting_app`, independent
/// of the reminder's current enabled flag.
pub(crate) fn cancellation_status(
    conn: &Connection,
    reminder: Option<&Reminder>,
) -> CoreResult<Option<CancellationStatus>> {
    let Some(reminder) = reminder else { return Ok(None) };
    let pending: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM notification_intents
         WHERE reminder_id = ?1 AND kind = 'cancel' AND state IN ('pending', 'attempting'))",
        [reminder.id.to_string()],
        |row| row.get(0),
    )?;
    Ok(pending.then_some(CancellationStatus { state: "pending", reason: "awaiting_app" }))
}
