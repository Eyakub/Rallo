use rusqlite::Transaction;
use serde::Serialize;

use super::model::{CancellationStatus, DisabledReason, SchedulingStatus};
use super::repository;
use super::time::{self, TimeSpec};
use crate::items::model::{Item, ItemStatus, ItemView, MutationOptions, MutationOutcome};
use crate::items::repository as items_repository;
use crate::items::service as items_service;
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::shared::{ids, text};
use crate::storage::database::{Store, bump_revision};

#[derive(Serialize)]
struct CreateReminderInputs<'a> {
    command: &'static str,
    text: &'a str,
    #[serde(flatten)]
    time: &'a TimeSpec,
}

#[derive(Serialize)]
struct SelectorInputs<'a> {
    command: &'static str,
    selector: &'a str,
    if_revision: Option<i64>,
}

#[derive(Serialize)]
struct RescheduleInputs<'a> {
    command: &'static str,
    selector: &'a str,
    #[serde(flatten)]
    time: &'a TimeSpec,
    if_revision: Option<i64>,
}

#[derive(Serialize)]
struct SnoozeInputs<'a> {
    command: &'static str,
    selector: &'a str,
    duration: &'a str,
    if_revision: Option<i64>,
}

fn no_reminder_error() -> CoreError {
    CoreError::conflict(ErrorCode::NoReminder, "item has no reminder")
}

/// `reschedule`/`snooze` precondition (0003 §3): open and nondeleted.
fn open_and_nondeleted_precondition(tx: &Transaction<'_>, item: &Item) -> CoreResult<()> {
    items_service::deleted_precondition(tx, item)?;
    if item.status != ItemStatus::Open {
        return Err(CoreError::conflict(ErrorCode::ItemNotOpen, "item is not open"));
    }
    Ok(())
}

/// `acknowledge`/`cancel-reminder` precondition (0003 §3): a reminder must
/// exist, regardless of the item's own state.
fn has_reminder_precondition(tx: &Transaction<'_>, item: &Item) -> CoreResult<()> {
    if repository::fetch_by_item(tx, item.id)?.is_none() {
        return Err(no_reminder_error());
    }
    Ok(())
}

/// `snooze` precondition (0003 §3): open, nondeleted, and a reminder exists.
fn open_nondeleted_has_reminder_precondition(tx: &Transaction<'_>, item: &Item) -> CoreResult<()> {
    open_and_nondeleted_precondition(tx, item)?;
    has_reminder_precondition(tx, item)
}

/// `acknowledge`/`cancel-reminder` no-op check (0003 §3): already inactive
/// (or, defensively, no reminder at all — the precondition rules that out).
fn reminder_not_active(tx: &Transaction<'_>, item: &Item) -> CoreResult<bool> {
    Ok(match repository::fetch_by_item(tx, item.id)? {
        Some(reminder) => !reminder.enabled,
        None => true,
    })
}

impl Store {
    /// Scheduling status for an item's reminder, or `None` without one.
    pub fn scheduling_status(&self, item: &ItemView) -> CoreResult<Option<SchedulingStatus>> {
        repository::scheduling_status(self.conn(), item.reminder.as_ref())
    }

    /// Cancellation status for an item's reminder, or `None` without one.
    pub fn cancellation_status(&self, item: &ItemView) -> CoreResult<Option<CancellationStatus>> {
        repository::cancellation_status(self.conn(), item.reminder.as_ref())
    }

    /// `remind TEXT --in/--at` (0003 §3): a new open item with an enabled
    /// reminder at generation 1 and a pending schedule intent, created
    /// atomically. Capacity is always checked (the reminder is always new).
    /// The idempotency fingerprint carries the original time input (e.g.
    /// `"20m"`), never the computed deadline, so a retried request replays
    /// the original deadline even after the clock has moved on.
    pub fn create_reminder(
        &mut self,
        text_input: &str,
        when: &TimeSpec,
        request_id: Option<&str>,
    ) -> CoreResult<MutationOutcome> {
        let note_text = text::validate_note_text(text_input)?.to_owned();
        let parsed_time = time::parse(when)?;
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let inputs = CreateReminderInputs { command: "create_reminder", text: &note_text, time: when };
        let fingerprint = match items_service::check_receipt(&tx, request_id, &inputs)? {
            items_service::ReceiptLookup::Replay(replayed) => {
                tx.commit()?;
                return Ok(*replayed);
            }
            items_service::ReceiptLookup::Fresh(fingerprint) => Some(fingerprint),
            items_service::ReceiptLookup::None => None,
        };

        repository::check_capacity(&tx)?;
        let resolved = parsed_time.resolve(now)?;

        let id = ids::new_id();
        let item = Item {
            short_key: ids::short_key(&id),
            id,
            text: note_text.clone(),
            status: ItemStatus::Open,
            created_at_ms: now,
            updated_at_ms: now,
            completed_at_ms: None,
            deleted_at_ms: None,
            revision: 1,
        };
        items_repository::insert(&tx, &item, &text::match_key(&note_text))?;
        repository::insert_new(
            &tx,
            id,
            resolved.deadline_ms,
            when.raw(),
            resolved.input_kind,
            resolved.input_offset_seconds,
            now,
        )?;
        crate::pet::increment_save_seq(&tx)?;
        bump_revision(&tx)?;

        let view = items_repository::build_item_view(&tx, item)?;
        items_service::store_receipt(
            &tx,
            request_id,
            fingerprint.as_deref(),
            "create_reminder",
            view.item.id,
            true,
            view.item.revision,
            now,
        )?;
        let result = items_service::outcome(&tx, view, true, false)?;
        tx.commit()?;
        Ok(result)
    }

    /// `reschedule ID --in/--at` (0003 §3): open, nondeleted items only.
    /// Creates a reminder if the item has none; otherwise re-arms the
    /// existing one (new deadline/input, enabled, ack and disabled-reason
    /// cleared, generation bumped). Always changes state when the
    /// preconditions pass — never a no-op. A capacity check only runs if the
    /// reminder was not already active.
    pub fn reschedule(
        &mut self,
        selector: &str,
        when: &TimeSpec,
        opts: &MutationOptions,
    ) -> CoreResult<MutationOutcome> {
        let parsed_time = time::parse(when)?;
        let raw_input = when.raw().to_owned();
        let inputs = RescheduleInputs { command: "reschedule", selector, time: when, if_revision: opts.if_revision };
        items_service::mutate_by_selector(
            self,
            "reschedule",
            selector,
            opts,
            &inputs,
            open_and_nondeleted_precondition,
            |_tx, _item| Ok(false),
            move |tx, item, now| {
                let resolved = parsed_time.resolve(now)?;
                let existing = repository::fetch_by_item(tx, item.id)?;
                let already_active = existing.as_ref().is_some_and(|reminder| reminder.enabled);
                if !already_active {
                    repository::check_capacity(tx)?;
                }
                match existing {
                    None => {
                        repository::insert_new(
                            tx,
                            item.id,
                            resolved.deadline_ms,
                            &raw_input,
                            resolved.input_kind,
                            resolved.input_offset_seconds,
                            now,
                        )?;
                    }
                    Some(existing) => {
                        repository::rearm(
                            tx,
                            existing.id,
                            resolved.deadline_ms,
                            &raw_input,
                            resolved.input_kind,
                            resolved.input_offset_seconds,
                            now,
                        )?;
                    }
                }
                items_repository::touch(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `snooze ID --in` (0003 §3): `--in` syntax only; requires an existing
    /// reminder on an open, nondeleted item. Always changes state when the
    /// preconditions pass — never a no-op. A capacity check only runs if the
    /// reminder was not already active.
    pub fn snooze(&mut self, selector: &str, duration: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let spec = TimeSpec::In(duration.to_owned());
        let parsed_time = time::parse(&spec)?;
        let raw_input = duration.to_owned();
        let inputs = SnoozeInputs { command: "snooze", selector, duration, if_revision: opts.if_revision };
        items_service::mutate_by_selector(
            self,
            "snooze",
            selector,
            opts,
            &inputs,
            open_nondeleted_has_reminder_precondition,
            |_tx, _item| Ok(false),
            move |tx, item, now| {
                let resolved = parsed_time.resolve(now)?;
                let existing =
                    repository::fetch_by_item(tx, item.id)?.expect("precondition guarantees a reminder exists");
                if !existing.enabled {
                    repository::check_capacity(tx)?;
                }
                repository::rearm(
                    tx,
                    existing.id,
                    resolved.deadline_ms,
                    &raw_input,
                    resolved.input_kind,
                    resolved.input_offset_seconds,
                    now,
                )?;
                items_repository::touch(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `acknowledge ID` (0003 §3): requires a reminder. An active reminder is
    /// disabled `acknowledged` (stamping `acknowledged_at_ms`) with a cancel
    /// intent; an already-inactive one is a no-op.
    pub fn acknowledge(&mut self, selector: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let inputs = SelectorInputs { command: "acknowledge", selector, if_revision: opts.if_revision };
        items_service::mutate_by_selector(
            self,
            "acknowledge",
            selector,
            opts,
            &inputs,
            has_reminder_precondition,
            reminder_not_active,
            |tx, item, now| {
                repository::disable_active(tx, item.id, DisabledReason::Acknowledged, now)?;
                items_repository::touch(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `cancel-reminder ID` (0003 §3): requires a reminder. An active
    /// reminder is disabled `cancelled` with a cancel intent; an
    /// already-inactive one is a no-op.
    pub fn cancel_reminder(&mut self, selector: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let inputs = SelectorInputs { command: "cancel_reminder", selector, if_revision: opts.if_revision };
        items_service::mutate_by_selector(
            self,
            "cancel_reminder",
            selector,
            opts,
            &inputs,
            has_reminder_precondition,
            reminder_not_active,
            |tx, item, now| {
                repository::disable_active(tx, item.id, DisabledReason::Cancelled, now)?;
                items_repository::touch(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }
}
