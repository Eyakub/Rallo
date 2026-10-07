use rusqlite::Transaction;
use serde::Serialize;
use serde_json::json;
use uuid::Uuid;

use super::model::{Item, ItemStatus, ItemView, MutationOptions, MutationOutcome};
use super::query::{ListQuery, Page, SearchQuery};
use super::repository;
use crate::reminders;
use crate::reminders::model::DisabledReason;
use crate::shared::errors::{ConflictDetail, CoreError, CoreResult, ErrorCode};
use crate::shared::idempotency;
use crate::shared::{ids, text};
use crate::storage::database::{Store, bump_revision};

/// Default page size for listings; callers choose whether to clamp or pass it
/// straight through (`ListQuery`/`SearchQuery` reject anything outside 1-200).
pub const DEFAULT_PAGE_SIZE: u32 = 50;

#[derive(Serialize)]
struct CreateNoteInputs<'a> {
    command: &'static str,
    text: &'a str,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    images: Vec<String>,
}

#[derive(Serialize)]
struct SelectorInputs<'a> {
    command: &'static str,
    selector: &'a str,
    if_revision: Option<i64>,
}

#[derive(Serialize)]
struct EditTextInputs<'a> {
    command: &'static str,
    selector: &'a str,
    text: &'a str,
    if_revision: Option<i64>,
}

#[derive(Serialize)]
struct DeleteByTextInputs<'a> {
    command: &'static str,
    text: &'a str,
}

/// Outcome of the request-id check that opens every mutation (0003 §7),
/// performed before resolving any selector or checking any revision.
///
/// `pub(crate)`: reminder mutations (`reminders::service`) reuse this same
/// pipeline rather than duplicating it.
pub(crate) enum ReceiptLookup {
    /// No request id was supplied.
    None,
    /// First time seeing this request id; store a receipt with this
    /// fingerprint if the command succeeds.
    Fresh(String),
    /// A matching receipt exists: replay it against the current snapshot.
    Replay(Box<MutationOutcome>),
}

pub(crate) fn check_receipt(
    tx: &Transaction<'_>,
    request_id: Option<&str>,
    inputs: &impl Serialize,
) -> CoreResult<ReceiptLookup> {
    let Some(request_id) = request_id else { return Ok(ReceiptLookup::None) };
    idempotency::validate_request_id(request_id)?;
    let fingerprint = idempotency::fingerprint(inputs);
    match idempotency::lookup(tx, request_id)? {
        Some(receipt) if receipt.fingerprint == fingerprint => {
            let item_id = receipt.item_id.expect("every mutation receipt records its affected item");
            let item = repository::get_by_id(tx, item_id)?.expect("a receipted item is only ever soft-deleted");
            let view = repository::build_item_view(tx, item)?;
            let changed = receipt.result.get("changed").and_then(serde_json::Value::as_bool).unwrap_or(false);
            Ok(ReceiptLookup::Replay(Box::new(outcome(tx, view, changed, true)?)))
        }
        Some(_) => Err(CoreError::conflict(
            ErrorCode::RequestIdConflict,
            format!("request id \"{request_id}\" was already used with different inputs"),
        )),
        None => Ok(ReceiptLookup::Fresh(fingerprint)),
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn store_receipt(
    tx: &Transaction<'_>,
    request_id: Option<&str>,
    fingerprint: Option<&str>,
    command_kind: &str,
    item_id: Uuid,
    changed: bool,
    revision: i64,
    now_ms: i64,
) -> CoreResult<()> {
    let (Some(request_id), Some(fingerprint)) = (request_id, fingerprint) else { return Ok(()) };
    let result = json!({ "item_id": item_id, "changed": changed, "revision": revision });
    idempotency::insert(tx, request_id, fingerprint, command_kind, Some(item_id), &result, now_ms)
}

pub(crate) fn outcome(
    conn: &rusqlite::Connection,
    item: ItemView,
    changed: bool,
    replayed: bool,
) -> CoreResult<MutationOutcome> {
    let scheduling = reminders::repository::scheduling_status(conn, item.reminder.as_ref())?;
    let cancellation = reminders::repository::cancellation_status(conn, item.reminder.as_ref())?;
    Ok(MutationOutcome { item, changed, replayed, scheduling, cancellation })
}

enum Guard {
    NoOp(Item),
    Proceed(Item),
}

/// Resolve → precondition → already-in-target no-op → revision guard (0003
/// §9), shared by every ID-based mutation.
///
/// `precondition` and `already_in_target` take the transaction as well as
/// the item: reminder mutations (`reminders::service`) need it to check
/// whether the item's reminder exists or is active, which `Item` alone
/// cannot answer.
fn guard(
    tx: &Transaction<'_>,
    selector: &str,
    if_revision: Option<i64>,
    precondition: impl FnOnce(&Transaction<'_>, &Item) -> CoreResult<()>,
    already_in_target: impl FnOnce(&Transaction<'_>, &Item) -> CoreResult<bool>,
) -> CoreResult<Guard> {
    let item = repository::resolve(tx, selector)?;
    precondition(tx, &item)?;
    if already_in_target(tx, &item)? {
        return Ok(Guard::NoOp(item));
    }
    if let Some(expected) = if_revision
        && item.revision != expected
    {
        let view = repository::build_item_view(tx, item.clone())?;
        return Err(CoreError::conflict_detail(
            ErrorCode::RevisionConflict,
            format!("expected revision {expected}, found {}", item.revision),
            ConflictDetail::Current { item: view },
        ));
    }
    Ok(Guard::Proceed(item))
}

pub(crate) fn deleted_precondition(_tx: &Transaction<'_>, item: &Item) -> CoreResult<()> {
    if item.deleted_at_ms.is_some() {
        Err(CoreError::conflict(ErrorCode::ItemDeleted, "item is deleted"))
    } else {
        Ok(())
    }
}

fn no_precondition(_tx: &Transaction<'_>, _item: &Item) -> CoreResult<()> {
    Ok(())
}

/// Shared receipt → guard → apply → receipt-store → outcome pipeline for the
/// ID-based mutations (`complete`, `reopen`, `delete`, `restore`, `edit_text`,
/// and — via `reminders::service` — `reschedule`, `snooze`, `acknowledge`,
/// `cancel_reminder`).
#[allow(clippy::too_many_arguments)]
pub(crate) fn mutate_by_selector(
    store: &mut Store,
    command_kind: &'static str,
    selector: &str,
    opts: &MutationOptions,
    inputs: &impl Serialize,
    precondition: impl FnOnce(&Transaction<'_>, &Item) -> CoreResult<()>,
    already_in_target: impl FnOnce(&Transaction<'_>, &Item) -> CoreResult<bool>,
    apply: impl FnOnce(&Transaction<'_>, &Item, i64) -> CoreResult<()>,
) -> CoreResult<MutationOutcome> {
    let now = store.now_ms();
    let tx = store.write_tx()?;

    let fingerprint = match check_receipt(&tx, opts.request_id.as_deref(), inputs)? {
        ReceiptLookup::Replay(replayed) => {
            tx.commit()?;
            return Ok(*replayed);
        }
        ReceiptLookup::Fresh(fingerprint) => Some(fingerprint),
        ReceiptLookup::None => None,
    };

    let (item, changed) = match guard(&tx, selector, opts.if_revision, precondition, already_in_target)? {
        Guard::NoOp(item) => (item, false),
        Guard::Proceed(item) => {
            apply(&tx, &item, now)?;
            let updated = repository::get_by_id(&tx, item.id)?.expect("the item was just updated");
            (updated, true)
        }
    };

    let view = repository::build_item_view(&tx, item)?;
    store_receipt(
        &tx,
        opts.request_id.as_deref(),
        fingerprint.as_deref(),
        command_kind,
        view.item.id,
        changed,
        view.item.revision,
        now,
    )?;
    let result = outcome(&tx, view, changed, false)?;
    tx.commit()?;
    Ok(result)
}

impl Store {
    /// Durably stores a new open note. Never has a reminder or preexisting
    /// candidates, so scheduling/cancellation are always `None`.
    pub fn create_note(&mut self, note_text: &str, request_id: Option<&str>) -> CoreResult<MutationOutcome> {
        self.create_note_with_images(note_text, &[], request_id)
    }

    /// `rallo note … --image` (0018): the image files are written first, then
    /// one transaction inserts the note and their rows; if that doesn't
    /// commit (or replays), the files are removed again.
    pub fn create_note_with_images(
        &mut self,
        note_text: &str,
        images: &[Vec<u8>],
        request_id: Option<&str>,
    ) -> CoreResult<MutationOutcome> {
        let note_text = text::validate_note_content(note_text, !images.is_empty())?.to_owned();
        let kinds = crate::images::format::check_batch(images, 0)?;
        let id = ids::new_id();
        let new_images = crate::images::files::new_images(images, &kinds);
        let written = crate::images::files::write_all(self.data_dir(), id, &new_images)?;
        let result = self.insert_note(id, &note_text, &new_images, crate::images::format::digests(images), request_id);
        if !matches!(&result, Ok(outcome) if !outcome.replayed) {
            written.discard();
        }
        result
    }

    fn insert_note(
        &mut self,
        id: Uuid,
        note_text: &str,
        new_images: &[crate::images::files::NewImage<'_>],
        digests: Vec<String>,
        request_id: Option<&str>,
    ) -> CoreResult<MutationOutcome> {
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let inputs = CreateNoteInputs { command: "create_note", text: note_text, images: digests };
        let fingerprint = match check_receipt(&tx, request_id, &inputs)? {
            ReceiptLookup::Replay(replayed) => {
                tx.commit()?;
                return Ok(*replayed);
            }
            ReceiptLookup::Fresh(fingerprint) => Some(fingerprint),
            ReceiptLookup::None => None,
        };

        let item = Item {
            short_key: ids::short_key(&id),
            id,
            text: note_text.to_owned(),
            status: ItemStatus::Open,
            created_at_ms: now,
            updated_at_ms: now,
            completed_at_ms: None,
            deleted_at_ms: None,
            revision: 1,
        };
        repository::insert(&tx, &item, &text::match_key(note_text))?;
        crate::images::repository::insert(&tx, id, new_images, now)?;
        crate::pet::increment_save_seq(&tx)?;
        bump_revision(&tx)?;
        let view = repository::build_item_view(&tx, item)?;
        store_receipt(
            &tx,
            request_id,
            fingerprint.as_deref(),
            "create_note",
            view.item.id,
            true,
            view.item.revision,
            now,
        )?;
        let result = outcome(&tx, view, true, false)?;
        tx.commit()?;
        Ok(result)
    }

    /// Resolves a selector to its current snapshot (0003 §6). Includes
    /// deleted items, matching every other selector-accepting command.
    pub fn get_item(&self, selector: &str) -> CoreResult<ItemView> {
        let item = repository::resolve(self.conn(), selector)?;
        repository::build_item_view(self.conn(), item)
    }

    pub fn list(&self, query: ListQuery) -> CoreResult<Page<ItemView>> {
        repository::list(self.conn(), &query, self.now_ms())
    }

    pub fn search(&self, query: SearchQuery) -> CoreResult<Page<ItemView>> {
        repository::search(self.conn(), &query)
    }

    /// `edit ID --text` (0003 §3): identical text is a no-op; otherwise
    /// updates the text/match_key and, only when previews are enabled and the
    /// reminder is active with a future deadline, queues a same-deadline
    /// payload refresh.
    pub fn edit_text(&mut self, selector: &str, new_text: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let new_text = text::validate_note_length(new_text)?.to_owned();
        let preview_enabled = self.preview_text_enabled()?;
        let inputs = EditTextInputs { command: "edit_text", selector, text: &new_text, if_revision: opts.if_revision };
        mutate_by_selector(
            self,
            "edit_text",
            selector,
            opts,
            &inputs,
            |tx, item| {
                deleted_precondition(tx, item)?;
                if new_text.is_empty() && crate::images::repository::count(tx, item.id)? == 0 {
                    return Err(CoreError::invalid(ErrorCode::TextEmpty, "a note needs text or an image"));
                }
                Ok(())
            },
            |_tx, item| Ok(item.text == new_text),
            |tx, item, now| {
                let match_key = text::match_key(&new_text);
                repository::update_text(tx, item.id, &new_text, &match_key, now)?;
                if preview_enabled {
                    reminders::repository::schedule_refresh_if_active(tx, item.id, now)?;
                }
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `done ID` (0003 §3): disables an active reminder with `item_completed`
    /// and a cancel intent. Already-done is a no-op.
    pub fn complete(&mut self, selector: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let inputs = SelectorInputs { command: "complete", selector, if_revision: opts.if_revision };
        mutate_by_selector(
            self,
            "complete",
            selector,
            opts,
            &inputs,
            deleted_precondition,
            |_tx, item| Ok(item.status == ItemStatus::Done),
            |tx, item, now| {
                repository::mark_done(tx, item.id, now)?;
                reminders::repository::disable_active(tx, item.id, DisabledReason::ItemCompleted, now)?;
                crate::pet::increment_completion_seq(tx)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `reopen ID` (0003 §3): never re-enables a reminder. Already-open is a
    /// no-op.
    pub fn reopen(&mut self, selector: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let inputs = SelectorInputs { command: "reopen", selector, if_revision: opts.if_revision };
        mutate_by_selector(
            self,
            "reopen",
            selector,
            opts,
            &inputs,
            deleted_precondition,
            |_tx, item| Ok(item.status == ItemStatus::Open),
            |tx, item, now| {
                repository::mark_open(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `delete ID` (0003 §3): soft-deletes, keeping status, and disables an
    /// active reminder with `item_deleted` and a cancel intent.
    /// Already-deleted is a no-op (even against a stale `--if-revision`).
    pub fn delete(&mut self, selector: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let inputs = SelectorInputs { command: "delete", selector, if_revision: opts.if_revision };
        mutate_by_selector(
            self,
            "delete",
            selector,
            opts,
            &inputs,
            no_precondition,
            |_tx, item| Ok(item.deleted_at_ms.is_some()),
            |tx, item, now| {
                repository::mark_deleted(tx, item.id, now)?;
                reminders::repository::disable_active(tx, item.id, DisabledReason::ItemDeleted, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `restore ID` (0003 §3): clears `deleted_at`, keeping prior open/done
    /// status. Never re-enables a reminder. Not-deleted is a no-op.
    pub fn restore(&mut self, selector: &str, opts: &MutationOptions) -> CoreResult<MutationOutcome> {
        let inputs = SelectorInputs { command: "restore", selector, if_revision: opts.if_revision };
        mutate_by_selector(
            self,
            "restore",
            selector,
            opts,
            &inputs,
            |tx, item| {
                if item.deleted_at_ms.is_some()
                    && item.text.trim().is_empty()
                    && crate::images::repository::count(tx, item.id)? == 0
                {
                    return Err(CoreError::invalid(
                        ErrorCode::TextEmpty,
                        "nothing left to restore: its images were removed 30 days after it was deleted",
                    ));
                }
                Ok(())
            },
            |_tx, item| Ok(item.deleted_at_ms.is_none()),
            |tx, item, now| {
                repository::mark_restored(tx, item.id, now)?;
                bump_revision(tx)?;
                Ok(())
            },
        )
    }

    /// `delete --text` (0003 §8): one transaction resolves the exact
    /// `match_key` among nondeleted items and deletes the sole match
    /// atomically. Zero matches is `ITEM_NOT_FOUND`; more than one is
    /// `AMBIGUOUS_ITEM` with up to 10 candidates and the true total. Does not
    /// accept `--if-revision` (there is no ID to guard yet).
    pub fn delete_by_text(&mut self, text_input: &str, request_id: Option<&str>) -> CoreResult<MutationOutcome> {
        if text_input.trim().is_empty() {
            return Err(CoreError::invalid(ErrorCode::TextEmpty, "search text is empty"));
        }
        let now = self.now_ms();
        let tx = self.write_tx()?;

        let inputs = DeleteByTextInputs { command: "delete_by_text", text: text_input };
        let fingerprint = match check_receipt(&tx, request_id, &inputs)? {
            ReceiptLookup::Replay(replayed) => {
                tx.commit()?;
                return Ok(*replayed);
            }
            ReceiptLookup::Fresh(fingerprint) => Some(fingerprint),
            ReceiptLookup::None => None,
        };

        let match_key = text::match_key(text_input);
        let matches = repository::find_exact_nondeleted(&tx, &match_key)?;
        let item = match matches.len() {
            0 => return Err(CoreError::not_found(ErrorCode::ItemNotFound, "no item matches that text")),
            1 => {
                let item = matches.into_iter().next().expect("length checked above");
                repository::mark_deleted(&tx, item.id, now)?;
                reminders::repository::disable_active(&tx, item.id, DisabledReason::ItemDeleted, now)?;
                bump_revision(&tx)?;
                repository::get_by_id(&tx, item.id)?.expect("the item was just updated")
            }
            _ => {
                let total = repository::count_exact_nondeleted(&tx, &match_key)?;
                let candidates = matches
                    .into_iter()
                    .take(10)
                    .map(|item| repository::build_item_view(&tx, item))
                    .collect::<CoreResult<Vec<_>>>()?;
                return Err(CoreError::conflict_detail(
                    ErrorCode::AmbiguousItem,
                    format!("{total} items match that text"),
                    ConflictDetail::Candidates { total, candidates },
                ));
            }
        };

        let view = repository::build_item_view(&tx, item)?;
        store_receipt(
            &tx,
            request_id,
            fingerprint.as_deref(),
            "delete_by_text",
            view.item.id,
            true,
            view.item.revision,
            now,
        )?;
        let result = outcome(&tx, view, true, false)?;
        tx.commit()?;
        Ok(result)
    }
}
