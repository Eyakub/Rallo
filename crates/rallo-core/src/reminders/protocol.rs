//! M2 notification protocol (0005): Rust decides, Swift observes and acts.
//!
//! Swift never infers scheduling state. It reports native evidence
//! (`record_native_observations`), asks for the next piece of work
//! (`next_platform_work`), performs it (`begin_platform_attempt` /
//! `finish_platform_attempt`), and reports notification-action taps
//! (`apply_notification_action`). All SQL for the protocol lives here.

use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use uuid::Uuid;

use super::model::{DisabledReason, InputKind};
use super::repository::{self, IntentKind};
use crate::items::model::ItemView;
use crate::items::repository as items_repository;
use crate::shared::errors::{CoreError, CoreResult};
use crate::shared::signal;
use crate::storage::database::{Store, bump_revision};

/// Half of the measured 100-per-app pending-request limit (0005, platform
/// observations): past this many Rallo-owned pending requests, schedule work
/// stays `pending`/`native_capacity` rather than risk evicting an existing one.
pub const NATIVE_PENDING_CAPACITY_THRESHOLD: u32 = 48;

/// A native `add()`'s trigger is never early (§ "platform observations"), but
/// a schedule can be applied only once evidence shows a future deadline is
/// truly still pending; this margin absorbs the round trip to record evidence.
const FUTURE_DEADLINE_MARGIN_MS: i64 = 2_000;

/// Acceptance window for a readback trigger: `[deadline, deadline + 1000)`,
/// since sub-second deadlines round up to the next whole second.
const TRIGGER_WINDOW_MS: i64 = 1_000;

const AUTHORIZATION_KEY: &str = "notifications.authorization";
const AUTHORIZATION_OBSERVED_AT_KEY: &str = "notifications.authorization_observed_at_ms";
const PENDING_OBSERVED_COUNT_KEY: &str = "notifications.pending_observed_count";

/// Mirrors `UNAuthorizationStatus`. Stored in `metadata` as an integer code
/// (the column is `INTEGER NOT NULL`; no schema change is needed for it).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationAuthorization {
    NotDetermined,
    Denied,
    Authorized,
    Provisional,
    Ephemeral,
}

impl NotificationAuthorization {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::NotDetermined => "not_determined",
            Self::Denied => "denied",
            Self::Authorized => "authorized",
            Self::Provisional => "provisional",
            Self::Ephemeral => "ephemeral",
        }
    }

    fn code(self) -> i64 {
        match self {
            Self::NotDetermined => 0,
            Self::Denied => 1,
            Self::Authorized => 2,
            Self::Provisional => 3,
            Self::Ephemeral => 4,
        }
    }

    fn from_code(code: i64) -> Option<Self> {
        match code {
            0 => Some(Self::NotDetermined),
            1 => Some(Self::Denied),
            2 => Some(Self::Authorized),
            3 => Some(Self::Provisional),
            4 => Some(Self::Ephemeral),
            _ => None,
        }
    }
}

/// One request Swift observed in `UNUserNotificationCenter`'s pending or
/// delivered lists, filtered to this store's own identifier prefix.
/// `reminder_id`/`generation` come from the request's `userInfo`; `None`
/// means missing or unparsable. `trigger_ms` is the pending request's
/// `UNCalendarNotificationTrigger` next-fire instant; always `None` for a
/// delivered request (it has already fired).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeRequest {
    pub identifier: String,
    pub reminder_id: Option<Uuid>,
    pub generation: Option<i64>,
    pub trigger_ms: Option<i64>,
}

/// Identifiers Swift should remove from `UNUserNotificationCenter`, computed
/// by `record_native_observations`. Both lists are limited to this store's
/// own identifier prefix.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CleanupPlan {
    pub remove_pending: Vec<String>,
    pub remove_delivered: Vec<String>,
}

/// One unit of native work `next_platform_work` hands to Swift.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlatformWork {
    Schedule {
        intent_id: i64,
        reminder_id: Uuid,
        item_id: Uuid,
        generation: i64,
        deadline_ms: i64,
        identifier: String,
        title: String,
        body: String,
    },
    Cancel {
        intent_id: i64,
        reminder_id: Uuid,
        generation: i64,
        identifier: String,
    },
}

/// Result of asking for the next piece of native work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NextWork {
    Work(PlatformWork),
    /// No work is actionable right now. `next_wake_at_ms` is the earliest
    /// backoff expiry among blocked intents, if any (permission and capacity
    /// blocks have no timer; they resume on their own triggers).
    Idle {
        next_wake_at_ms: Option<i64>,
    },
}

/// Proof that `begin_platform_attempt` durably marked an intent `attempting`
/// before any native effect. `finish_platform_attempt` compares-and-sets on
/// this triple so a stale attempt (superseded, or a later attempt already
/// started) changes nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttemptToken {
    pub intent_id: i64,
    pub generation: i64,
    pub attempt: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BeginOutcome {
    Started(AttemptToken),
    Superseded,
}

/// What Swift observed after attempting a native effect for `finish_platform_attempt`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NativeOutcome {
    /// Schedule: `add()` returned and pending readback listed the identifier
    /// with this trigger.
    Accepted {
        readback_trigger_ms: i64,
    },
    /// Cancel: `removePendingNotificationRequests` ran.
    Removed,
    /// Schedule: `add()` returned but pending readback lacks the identifier.
    NotConfirmed,
    TransientFailure {
        code: String,
    },
    PermissionDenied,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Finished {
    pub applied: bool,
    pub superseded: bool,
    pub retry_at_ms: Option<i64>,
}

/// A notification action's category identifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationAction {
    Done,
    Snooze10m,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StaleReason {
    Changed,
    Deleted,
    Missing,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActionOutcome {
    Applied(ItemView),
    Stale { item: Option<ItemView>, reason: StaleReason },
}

fn uuid_column(row: &Row<'_>, index: usize) -> rusqlite::Result<Uuid> {
    let raw: String = row.get(index)?;
    Uuid::parse_str(&raw)
        .map_err(|e| rusqlite::Error::FromSqlConversionFailure(index, rusqlite::types::Type::Text, Box::new(e)))
}

fn read_metadata_i64(conn: &Connection, key: &str) -> CoreResult<Option<i64>> {
    Ok(conn.query_row("SELECT value FROM metadata WHERE key = ?1", [key], |row| row.get(0)).optional()?)
}

fn write_metadata_i64(tx: &Transaction<'_>, key: &str, value: i64) -> CoreResult<()> {
    tx.execute(
        "INSERT INTO metadata (key, value) VALUES (?1, ?2)
         ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        params![key, value],
    )?;
    Ok(())
}

/// Last-observed authorization, or `NotDetermined` before the first drain pass.
pub(crate) fn read_authorization(conn: &Connection) -> CoreResult<NotificationAuthorization> {
    Ok(read_metadata_i64(conn, AUTHORIZATION_KEY)?
        .and_then(NotificationAuthorization::from_code)
        .unwrap_or(NotificationAuthorization::NotDetermined))
}

/// Retry backoff by attempt number: 1, 5, 30, then 60 s (capped).
fn backoff_delay_ms(attempt: i64) -> i64 {
    match attempt.max(1) {
        1 => 1_000,
        2 => 5_000,
        3 => 30_000,
        _ => 60_000,
    }
}

/// Sub-second deadlines round up to the next whole second (platform
/// observations): the same rule applied here to match a readback trigger.
fn round_up_to_second(deadline_ms: i64) -> i64 {
    let remainder = deadline_ms.rem_euclid(1_000);
    if remainder == 0 { deadline_ms } else { deadline_ms - remainder + 1_000 }
}

fn native_identifier(prefix: &str, reminder_id: Uuid) -> String {
    format!("{prefix}{reminder_id}")
}

fn fallback_title_and_body() -> (String, String) {
    ("Rallo reminder".to_owned(), "Open Rallo to see it.".to_owned())
}

/// The note's title line and the rest flattened to one line, mirroring the
/// app's `NoteParts` (`Notes/NoteRow.swift`): the first non-empty line is the
/// title, the remaining lines are trimmed and joined with spaces.
fn title_and_body(text: &str) -> (String, String) {
    let lines: Vec<&str> = text.lines().collect();
    match lines.iter().position(|line| !line.trim().is_empty()) {
        None => (text.trim().to_owned(), String::new()),
        Some(index) => {
            let title = lines[index].trim().to_owned();
            let body = lines[index + 1..]
                .iter()
                .map(|line| line.trim())
                .filter(|line| !line.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            (title, body)
        }
    }
}

/// `Some(enabled)` if the reminder exists, `None` if it does not.
fn reminder_enabled(tx: &Transaction<'_>, reminder_id: Uuid) -> CoreResult<Option<bool>> {
    Ok(tx
        .query_row("SELECT enabled FROM reminders WHERE id = ?1", [reminder_id.to_string()], |row| row.get::<_, i64>(0))
        .optional()?
        .map(|value| value != 0))
}

enum ObservationField {
    Pending,
    Delivered,
}

/// Upserts `notification_observations` for one `(reminder, generation)`
/// observation. A new generation resets the row (0005 step 2).
fn record_observation(
    tx: &Transaction<'_>,
    reminder_id: Uuid,
    generation: i64,
    now_ms: i64,
    field: ObservationField,
) -> CoreResult<()> {
    let reminder_id = reminder_id.to_string();
    let existing_generation: Option<i64> = tx
        .query_row("SELECT generation FROM notification_observations WHERE reminder_id = ?1", [&reminder_id], |row| {
            row.get(0)
        })
        .optional()?;
    if existing_generation == Some(generation) {
        let column = match field {
            ObservationField::Pending => "pending_observed_at_ms",
            ObservationField::Delivered => "delivered_observed_at_ms",
        };
        tx.execute(
            &format!("UPDATE notification_observations SET {column} = ?2, observed_at_ms = ?2 WHERE reminder_id = ?1"),
            params![reminder_id, now_ms],
        )?;
    } else {
        let (pending_val, delivered_val) = match field {
            ObservationField::Pending => (Some(now_ms), None),
            ObservationField::Delivered => (None, Some(now_ms)),
        };
        tx.execute(
            "INSERT INTO notification_observations
                (reminder_id, generation, accepted_at_ms, pending_observed_at_ms, delivered_observed_at_ms, observed_at_ms)
             VALUES (?1, ?2, NULL, ?3, ?4, ?5)
             ON CONFLICT (reminder_id) DO UPDATE SET
                generation = excluded.generation, accepted_at_ms = NULL,
                pending_observed_at_ms = excluded.pending_observed_at_ms,
                delivered_observed_at_ms = excluded.delivered_observed_at_ms,
                observed_at_ms = excluded.observed_at_ms",
            params![reminder_id, generation, pending_val, delivered_val, now_ms],
        )?;
    }
    Ok(())
}

/// Records acceptance evidence for `finish_platform_attempt`'s `Accepted`
/// outcome, same reset-on-new-generation rule as `record_observation`.
fn record_accepted(tx: &Transaction<'_>, reminder_id: Uuid, generation: i64, now_ms: i64) -> CoreResult<()> {
    let reminder_id = reminder_id.to_string();
    let existing_generation: Option<i64> = tx
        .query_row("SELECT generation FROM notification_observations WHERE reminder_id = ?1", [&reminder_id], |row| {
            row.get(0)
        })
        .optional()?;
    if existing_generation == Some(generation) {
        tx.execute(
            "UPDATE notification_observations SET accepted_at_ms = ?2, observed_at_ms = ?2 WHERE reminder_id = ?1",
            params![reminder_id, now_ms],
        )?;
    } else {
        tx.execute(
            "INSERT INTO notification_observations
                (reminder_id, generation, accepted_at_ms, pending_observed_at_ms, delivered_observed_at_ms, observed_at_ms)
             VALUES (?1, ?2, ?3, NULL, NULL, ?3)
             ON CONFLICT (reminder_id) DO UPDATE SET
                generation = excluded.generation, accepted_at_ms = excluded.accepted_at_ms,
                pending_observed_at_ms = NULL, delivered_observed_at_ms = NULL, observed_at_ms = excluded.observed_at_ms",
            params![reminder_id, generation, now_ms],
        )?;
    }
    Ok(())
}

fn mark_intent_applied(tx: &Transaction<'_>, intent_id: i64, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE notification_intents SET state = 'applied', resolved_at_ms = ?2 WHERE id = ?1",
        params![intent_id, now_ms],
    )?;
    Ok(())
}

fn abandon_intent(tx: &Transaction<'_>, intent_id: i64, error_code: &str, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE notification_intents SET state = 'abandoned', error_code = ?2, resolved_at_ms = ?3 WHERE id = ?1",
        params![intent_id, error_code, now_ms],
    )?;
    Ok(())
}

/// Sends an unresolved intent back to `pending` with a blocking/retry reason
/// (0005 `error_code` list). `next_attempt_at_ms = None` means no timer
/// (`permission_denied`, or lifting a `native_capacity` block for a crashed
/// attempt): it resumes on its own trigger instead.
fn reopen_pending(
    tx: &Transaction<'_>,
    intent_id: i64,
    error_code: Option<&str>,
    next_attempt_at_ms: Option<i64>,
) -> CoreResult<()> {
    tx.execute(
        "UPDATE notification_intents SET state = 'pending', error_code = ?2, next_attempt_at_ms = ?3 WHERE id = ?1",
        params![intent_id, error_code, next_attempt_at_ms],
    )?;
    Ok(())
}

fn set_error_code(tx: &Transaction<'_>, intent_id: i64, error_code: &str) -> CoreResult<()> {
    tx.execute("UPDATE notification_intents SET error_code = ?2 WHERE id = ?1", params![intent_id, error_code])?;
    Ok(())
}

struct AttemptingSchedule {
    intent_id: i64,
    reminder_id: Uuid,
    generation: i64,
    deadline_ms: i64,
}

fn fetch_attempting_schedule_intents(tx: &Transaction<'_>) -> CoreResult<Vec<AttemptingSchedule>> {
    let mut statement = tx.prepare(
        "SELECT ni.id, ni.reminder_id, ni.generation, r.deadline_ms
         FROM notification_intents ni JOIN reminders r ON r.id = ni.reminder_id
         WHERE ni.kind = 'schedule' AND ni.state = 'attempting'",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok(AttemptingSchedule {
                intent_id: row.get(0)?,
                reminder_id: uuid_column(row, 1)?,
                generation: row.get(2)?,
                deadline_ms: row.get(3)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

struct AppliedSchedule {
    intent_id: i64,
    reminder_id: Uuid,
    generation: i64,
    attempt_count: i64,
}

/// Applied schedule intents of the reminder's current generation whose
/// deadline is still comfortably in the future (0005 step 4).
fn fetch_applied_schedule_intents_with_future_deadline(
    tx: &Transaction<'_>,
    threshold_ms: i64,
) -> CoreResult<Vec<AppliedSchedule>> {
    let mut statement = tx.prepare(
        "SELECT ni.id, ni.reminder_id, ni.generation, ni.attempt_count
         FROM notification_intents ni JOIN reminders r ON r.id = ni.reminder_id AND r.generation = ni.generation
         WHERE ni.kind = 'schedule' AND ni.state = 'applied' AND r.enabled = 1 AND r.deadline_ms > ?1",
    )?;
    let rows = statement
        .query_map([threshold_ms], |row| {
            Ok(AppliedSchedule {
                intent_id: row.get(0)?,
                reminder_id: uuid_column(row, 1)?,
                generation: row.get(2)?,
                attempt_count: row.get(3)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

struct Candidate {
    intent_id: i64,
    kind: IntentKind,
    is_attempting: bool,
    attempt_count: i64,
    error_code: Option<String>,
    next_attempt_at_ms: Option<i64>,
    created_at_ms: i64,
    reminder_id: Uuid,
    generation: i64,
    enabled: bool,
    deadline_ms: i64,
    item_id: Uuid,
    item_text: String,
}

/// Every unresolved (`pending`/`attempting`) intent of its reminder's current
/// generation, with the fields `next_platform_work` needs to decide and to
/// build `PlatformWork`.
fn fetch_unresolved_candidates(tx: &Transaction<'_>) -> CoreResult<Vec<Candidate>> {
    let mut statement = tx.prepare(
        "SELECT ni.id, ni.kind, ni.state, ni.attempt_count, ni.error_code, ni.next_attempt_at_ms, ni.created_at_ms,
                ni.reminder_id, r.generation, r.enabled, r.deadline_ms, r.item_id, i.text
         FROM notification_intents ni
         JOIN reminders r ON r.id = ni.reminder_id AND r.generation = ni.generation
         JOIN items i ON i.id = r.item_id
         WHERE ni.state IN ('pending', 'attempting')",
    )?;
    let rows = statement
        .query_map([], |row| {
            let kind: String = row.get(1)?;
            let state: String = row.get(2)?;
            Ok(Candidate {
                intent_id: row.get(0)?,
                kind: IntentKind::parse(&kind).ok_or_else(|| {
                    rusqlite::Error::FromSqlConversionFailure(
                        1,
                        rusqlite::types::Type::Text,
                        "unknown intent kind".into(),
                    )
                })?,
                is_attempting: state == "attempting",
                attempt_count: row.get(3)?,
                error_code: row.get(4)?,
                next_attempt_at_ms: row.get(5)?,
                created_at_ms: row.get(6)?,
                reminder_id: uuid_column(row, 7)?,
                generation: row.get(8)?,
                enabled: row.get::<_, i64>(9)? != 0,
                deadline_ms: row.get(10)?,
                item_id: uuid_column(row, 11)?,
                item_text: row.get(12)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

impl Store {
    /// This store's identifier prefix: `rallo.reminder.<scope>.`, `<scope>`
    /// the same per-data-directory fnv1a64 used for the Darwin signal names.
    /// Every data directory shares one `UNUserNotificationCenter` (same app
    /// identity), so requests are scoped per directory to stay isolated.
    pub fn notification_prefix(&self) -> String {
        format!("rallo.reminder.{}.", signal::data_dir_scope(self.data_dir()))
    }

    /// Last-observed notification authorization, or `NotDetermined` before
    /// the first drain pass has run.
    pub fn notification_authorization(&self) -> CoreResult<NotificationAuthorization> {
        read_authorization(self.conn())
    }

    /// Called at the start of every drain pass with this store's own
    /// requests (0005 §"record_native_observations"). `pending`/`delivered`
    /// are filtered to this store's identifier prefix before anything else:
    /// every other request (another data directory, `rallo.probe.`, or
    /// anything else) is ignored entirely.
    pub fn record_native_observations(
        &mut self,
        authorization: NotificationAuthorization,
        pending: &[NativeRequest],
        delivered: &[NativeRequest],
    ) -> CoreResult<CleanupPlan> {
        let prefix = self.notification_prefix();
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let pending: Vec<&NativeRequest> = pending.iter().filter(|r| r.identifier.starts_with(&prefix)).collect();
        let delivered: Vec<&NativeRequest> = delivered.iter().filter(|r| r.identifier.starts_with(&prefix)).collect();

        let previous_authorization = read_metadata_i64(&tx, AUTHORIZATION_KEY)?;
        write_metadata_i64(&tx, AUTHORIZATION_KEY, authorization.code())?;
        write_metadata_i64(&tx, AUTHORIZATION_OBSERVED_AT_KEY, now)?;
        if previous_authorization != Some(authorization.code()) {
            bump_revision(&tx)?;
        }
        write_metadata_i64(&tx, PENDING_OBSERVED_COUNT_KEY, pending.len() as i64)?;

        for request in &pending {
            if let (Some(reminder_id), Some(generation)) = (request.reminder_id, request.generation)
                && reminder_enabled(&tx, reminder_id)?.is_some()
            {
                record_observation(&tx, reminder_id, generation, now, ObservationField::Pending)?;
            }
        }
        for request in &delivered {
            if let (Some(reminder_id), Some(generation)) = (request.reminder_id, request.generation)
                && reminder_enabled(&tx, reminder_id)?.is_some()
            {
                record_observation(&tx, reminder_id, generation, now, ObservationField::Delivered)?;
            }
        }

        // Evidence resolves crash windows: an `attempting` schedule intent
        // whose generation now reads back pending (with the right trigger)
        // or delivered is applied without a second `add()`.
        for attempt in fetch_attempting_schedule_intents(&tx)? {
            let delivered_evidence = delivered
                .iter()
                .any(|r| r.reminder_id == Some(attempt.reminder_id) && r.generation == Some(attempt.generation));
            let pending_evidence = !delivered_evidence
                && pending.iter().any(|r| {
                    r.reminder_id == Some(attempt.reminder_id)
                        && r.generation == Some(attempt.generation)
                        && r.trigger_ms == Some(round_up_to_second(attempt.deadline_ms))
                });
            if delivered_evidence || pending_evidence {
                mark_intent_applied(&tx, attempt.intent_id, now)?;
                bump_revision(&tx)?;
            }
        }

        // Evidence reopens silent losses: an `applied` schedule intent whose
        // deadline is still comfortably future but is neither pending nor
        // delivered has vanished from the native side.
        for applied in fetch_applied_schedule_intents_with_future_deadline(&tx, now + FUTURE_DEADLINE_MARGIN_MS)? {
            let observed = pending
                .iter()
                .any(|r| r.reminder_id == Some(applied.reminder_id) && r.generation == Some(applied.generation))
                || delivered
                    .iter()
                    .any(|r| r.reminder_id == Some(applied.reminder_id) && r.generation == Some(applied.generation));
            if !observed {
                let retry_at_ms = now + backoff_delay_ms(applied.attempt_count);
                reopen_pending(&tx, applied.intent_id, Some("missing_from_readback"), Some(retry_at_ms))?;
                bump_revision(&tx)?;
            }
        }

        let mut remove_pending = Vec::new();
        for request in &pending {
            let remove = match request.reminder_id {
                None => true,
                Some(id) => !reminder_enabled(&tx, id)?.unwrap_or(false),
            };
            if remove {
                remove_pending.push(request.identifier.clone());
            }
        }
        let mut remove_delivered = Vec::new();
        for request in &delivered {
            if let Some(id) = request.reminder_id
                && reminder_enabled(&tx, id)? == Some(false)
            {
                remove_delivered.push(request.identifier.clone());
            }
        }

        tx.commit()?;
        Ok(CleanupPlan { remove_pending, remove_delivered })
    }

    /// Mutating: may abandon elapsed schedule intents before choosing the
    /// next piece of work (0005 §"next_platform_work").
    pub fn next_platform_work(&mut self) -> CoreResult<NextWork> {
        let preview_enabled = self.preview_text_enabled()?;
        let prefix = self.notification_prefix();
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let authorization_denied = read_authorization(&tx)? == NotificationAuthorization::Denied;
        let capacity_gated = read_metadata_i64(&tx, PENDING_OBSERVED_COUNT_KEY)?.unwrap_or(0)
            >= i64::from(NATIVE_PENDING_CAPACITY_THRESHOLD);

        let mut candidates = fetch_unresolved_candidates(&tx)?;

        // An elapsed deadline is never submitted; it abandons instead.
        let mut elapsed = Vec::new();
        for candidate in &candidates {
            if candidate.kind == IntentKind::Schedule && candidate.deadline_ms <= now {
                let error_code = if candidate.is_attempting {
                    "delivery_unconfirmed"
                } else if candidate.attempt_count > 0 {
                    "deadline_elapsed_retrying"
                } else {
                    "deadline_elapsed_unattempted"
                };
                abandon_intent(&tx, candidate.intent_id, error_code, now)?;
                bump_revision(&tx)?;
                elapsed.push(candidate.intent_id);
            }
        }
        candidates.retain(|candidate| !elapsed.contains(&candidate.intent_id));

        let mut cancels: Vec<&Candidate> = candidates.iter().filter(|c| c.kind == IntentKind::Cancel).collect();
        cancels.sort_by_key(|c| c.created_at_ms);
        for cancel in cancels {
            if !cancel.is_attempting && cancel.next_attempt_at_ms.is_some_and(|next| next > now) {
                continue;
            }
            let work = PlatformWork::Cancel {
                intent_id: cancel.intent_id,
                reminder_id: cancel.reminder_id,
                generation: cancel.generation,
                identifier: native_identifier(&prefix, cancel.reminder_id),
            };
            tx.commit()?;
            return Ok(NextWork::Work(work));
        }

        let mut schedules: Vec<&Candidate> =
            candidates.iter().filter(|c| c.kind == IntentKind::Schedule && c.enabled).collect();
        schedules.sort_by_key(|c| c.deadline_ms);
        for schedule in schedules {
            if !schedule.is_attempting {
                if schedule.next_attempt_at_ms.is_some_and(|next| next > now) {
                    continue;
                }
                if authorization_denied && schedule.error_code.as_deref() == Some("permission_denied") {
                    continue;
                }
            }
            if capacity_gated {
                match (schedule.is_attempting, schedule.error_code.as_deref()) {
                    (true, _) => {
                        reopen_pending(&tx, schedule.intent_id, Some("native_capacity"), None)?;
                        bump_revision(&tx)?;
                    }
                    (false, Some("native_capacity")) => {}
                    (false, _) => {
                        set_error_code(&tx, schedule.intent_id, "native_capacity")?;
                        bump_revision(&tx)?;
                    }
                }
                continue;
            }
            let (title, body) =
                if preview_enabled { title_and_body(&schedule.item_text) } else { fallback_title_and_body() };
            let work = PlatformWork::Schedule {
                intent_id: schedule.intent_id,
                reminder_id: schedule.reminder_id,
                item_id: schedule.item_id,
                generation: schedule.generation,
                deadline_ms: schedule.deadline_ms,
                identifier: native_identifier(&prefix, schedule.reminder_id),
                title,
                body,
            };
            tx.commit()?;
            return Ok(NextWork::Work(work));
        }

        let next_wake_at_ms = candidates.iter().filter_map(|c| c.next_attempt_at_ms).filter(|&at| at > now).min();
        tx.commit()?;
        Ok(NextWork::Idle { next_wake_at_ms })
    }

    /// Durably marks an intent `attempting` before any native effect (0005
    /// §"begin_platform_attempt"). Commits before the caller touches
    /// `UserNotifications`.
    pub fn begin_platform_attempt(&mut self, intent_id: i64, generation: i64) -> CoreResult<BeginOutcome> {
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let row: Option<(String, String, i64, i64, i64, bool, i64)> = tx
            .query_row(
                "SELECT ni.kind, ni.state, ni.attempt_count, ni.generation, r.generation, r.enabled, r.deadline_ms
                 FROM notification_intents ni JOIN reminders r ON r.id = ni.reminder_id
                 WHERE ni.id = ?1",
                [intent_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get::<_, i64>(5)? != 0,
                        row.get(6)?,
                    ))
                },
            )
            .optional()?;
        let Some((kind, state, attempt_count, intent_generation, reminder_generation, enabled, deadline_ms)) = row
        else {
            return Ok(BeginOutcome::Superseded);
        };
        let eligible = intent_generation == generation
            && reminder_generation == generation
            && matches!(state.as_str(), "pending" | "attempting")
            && (kind != "schedule" || (enabled && deadline_ms > now));
        if !eligible {
            return Ok(BeginOutcome::Superseded);
        }

        let attempt = attempt_count + 1;
        tx.execute(
            "UPDATE notification_intents SET state = 'attempting', attempt_count = ?2, last_attempt_at_ms = ?3,
                 next_attempt_at_ms = NULL, error_code = NULL WHERE id = ?1",
            params![intent_id, attempt, now],
        )?;
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(BeginOutcome::Started(AttemptToken { intent_id, generation, attempt }))
    }

    /// Compare-and-set on `(intent_id, state = attempting, attempt_count)`
    /// (0005 §"finish_platform_attempt"). A stale token changes nothing.
    pub fn finish_platform_attempt(&mut self, token: AttemptToken, outcome: NativeOutcome) -> CoreResult<Finished> {
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let row: Option<(String, i64, i64, i64)> = tx
            .query_row(
                "SELECT ni.reminder_id, ni.generation, r.generation, r.deadline_ms
                 FROM notification_intents ni JOIN reminders r ON r.id = ni.reminder_id
                 WHERE ni.id = ?1 AND ni.state = 'attempting' AND ni.attempt_count = ?2",
                params![token.intent_id, token.attempt],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let Some((reminder_id_raw, intent_generation, reminder_generation, deadline_ms)) = row else {
            return Ok(Finished { applied: false, superseded: true, retry_at_ms: None });
        };
        if intent_generation != token.generation || reminder_generation != token.generation {
            return Ok(Finished { applied: false, superseded: true, retry_at_ms: None });
        }
        let reminder_id = Uuid::parse_str(&reminder_id_raw)
            .map_err(|_| CoreError::storage("stored reminder id is not a valid UUID"))?;

        let backoff = backoff_delay_ms(token.attempt);
        let finished = match outcome {
            NativeOutcome::Accepted { readback_trigger_ms } => {
                let expected = round_up_to_second(deadline_ms);
                if (expected..expected + TRIGGER_WINDOW_MS).contains(&readback_trigger_ms) {
                    mark_intent_applied(&tx, token.intent_id, now)?;
                    record_accepted(&tx, reminder_id, token.generation, now)?;
                    Finished { applied: true, superseded: false, retry_at_ms: None }
                } else {
                    let retry_at_ms = now + backoff;
                    reopen_pending(&tx, token.intent_id, Some("trigger_mismatch"), Some(retry_at_ms))?;
                    Finished { applied: false, superseded: false, retry_at_ms: Some(retry_at_ms) }
                }
            }
            NativeOutcome::Removed => {
                mark_intent_applied(&tx, token.intent_id, now)?;
                Finished { applied: true, superseded: false, retry_at_ms: None }
            }
            NativeOutcome::NotConfirmed => {
                let retry_at_ms = now + backoff;
                reopen_pending(&tx, token.intent_id, Some("not_in_readback"), Some(retry_at_ms))?;
                Finished { applied: false, superseded: false, retry_at_ms: Some(retry_at_ms) }
            }
            NativeOutcome::TransientFailure { code } => {
                let retry_at_ms = now + backoff;
                reopen_pending(&tx, token.intent_id, Some(code.as_str()), Some(retry_at_ms))?;
                Finished { applied: false, superseded: false, retry_at_ms: Some(retry_at_ms) }
            }
            NativeOutcome::PermissionDenied => {
                reopen_pending(&tx, token.intent_id, Some("permission_denied"), None)?;
                Finished { applied: false, superseded: false, retry_at_ms: None }
            }
        };
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(finished)
    }

    /// A tapped notification action (0005 §"apply_notification_action"). The
    /// action applies only if `generation` is still current, the reminder is
    /// enabled, and the item is not deleted; otherwise `Stale`.
    pub fn apply_notification_action(
        &mut self,
        reminder_id: Uuid,
        generation: i64,
        action: NotificationAction,
    ) -> CoreResult<ActionOutcome> {
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let Some(reminder) = repository::fetch_by_id(&tx, reminder_id)? else {
            tx.commit()?;
            return Ok(ActionOutcome::Stale { item: None, reason: StaleReason::Missing });
        };
        let item = items_repository::get_by_id(&tx, reminder.item_id)?
            .expect("a reminder's item row always exists (soft delete only)");
        if item.deleted_at_ms.is_some() {
            let view = items_repository::build_item_view(&tx, item)?;
            tx.commit()?;
            return Ok(ActionOutcome::Stale { item: Some(view), reason: StaleReason::Deleted });
        }
        if reminder.generation != generation || !reminder.enabled {
            let view = items_repository::build_item_view(&tx, item)?;
            tx.commit()?;
            return Ok(ActionOutcome::Stale { item: Some(view), reason: StaleReason::Changed });
        }

        match action {
            NotificationAction::Done => {
                items_repository::mark_done(&tx, item.id, now)?;
                repository::disable_active(&tx, item.id, DisabledReason::ItemCompleted, now)?;
            }
            NotificationAction::Snooze10m => {
                let deadline_ms = now + 10 * 60 * 1_000;
                repository::rearm(&tx, reminder.id, deadline_ms, "10m", InputKind::Relative, None, now)?;
                items_repository::touch(&tx, item.id, now)?;
            }
        }
        bump_revision(&tx)?;

        let updated_item = items_repository::get_by_id(&tx, item.id)?.expect("the item was just updated");
        let view = items_repository::build_item_view(&tx, updated_item)?;
        tx.commit()?;
        Ok(ActionOutcome::Applied(view))
    }
}
