//! Folder mutations (0019 §5): one `BEGIN IMMEDIATE` transaction each, with
//! `--request-id` receipts (0003 §7) and one `change_revision` bump.

use rusqlite::Transaction;
use serde::Serialize;
use serde::de::DeserializeOwned;

use super::model::{
    DeleteNotes, Folder, FolderCount, FolderDeleteOutcome, FolderOutcome, FolderSelector, NotesDisposition,
    validate_name,
};
use super::repository;
use crate::items::service::soft_delete;
use crate::reminders;
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::shared::{idempotency, ids};
use crate::storage::database::{Store, bump_revision};

#[derive(Serialize)]
struct CreateInputs<'a> {
    command: &'static str,
    name: &'a str,
}

#[derive(Serialize)]
struct RenameInputs<'a> {
    command: &'static str,
    folder: Option<String>,
    name: &'a str,
}

#[derive(Serialize)]
struct DeleteInputs {
    command: &'static str,
    folder: Option<String>,
    notes: Option<&'static str>,
}

/// Request-id check for a folder command. Folder receipts store the whole
/// outcome (they have no item to re-read), so a replay returns it as it was.
enum Receipt<T> {
    /// Run the command; store a receipt with this fingerprint if there is one.
    Fresh(Option<String>),
    Replay(T),
}

fn check_receipt<T: DeserializeOwned>(
    tx: &Transaction<'_>,
    request_id: Option<&str>,
    inputs: &impl Serialize,
) -> CoreResult<Receipt<T>> {
    let Some(request_id) = request_id else { return Ok(Receipt::Fresh(None)) };
    idempotency::validate_request_id(request_id)?;
    let fingerprint = idempotency::fingerprint(inputs);
    match idempotency::lookup(tx, request_id)? {
        Some(receipt) if receipt.fingerprint == fingerprint => serde_json::from_value(receipt.result)
            .map(Receipt::Replay)
            .map_err(|e| CoreError::storage(format!("stored receipt has an invalid result: {e}"))),
        Some(_) => Err(CoreError::conflict(
            ErrorCode::RequestIdConflict,
            format!("request id \"{request_id}\" was already used with different inputs"),
        )),
        None => Ok(Receipt::Fresh(Some(fingerprint))),
    }
}

fn store_receipt(
    tx: &Transaction<'_>,
    request_id: Option<&str>,
    fingerprint: Option<&str>,
    command_kind: &str,
    outcome: &impl Serialize,
    now_ms: i64,
) -> CoreResult<()> {
    let (Some(request_id), Some(fingerprint)) = (request_id, fingerprint) else { return Ok(()) };
    let result = serde_json::to_value(outcome).expect("folder outcomes serialize");
    idempotency::insert(tx, request_id, fingerprint, command_kind, None, &result, now_ms)
}

fn built_in(action: &str) -> CoreError {
    CoreError::invalid(
        ErrorCode::FolderNameInvalid,
        format!("\u{201c}Notes\u{201d} is the built-in folder and can't be {action}"),
    )
}

impl Store {
    /// Notes first, then every folder alphabetically, with open counts.
    pub fn folders(&self) -> CoreResult<Vec<FolderCount>> {
        repository::counts(self.conn())
    }

    /// `folder create NAME` (0019 §5). A name another folder has (by key) is
    /// `FOLDER_EXISTS`.
    pub fn create_folder(&mut self, name: &str, request_id: Option<&str>) -> CoreResult<FolderOutcome> {
        let (name, key) = validate_name(name)?;
        let now = self.now_ms();
        let tx = self.write_tx()?;
        // The trimmed name as typed: 0003 §7 fingerprints original inputs, so `WORK` is not a retry of `Work`.
        let inputs = CreateInputs { command: "folder_create", name: &name };
        let fingerprint = match check_receipt::<FolderOutcome>(&tx, request_id, &inputs)? {
            Receipt::Replay(mut outcome) => {
                outcome.replayed = true;
                // 0003 §7: a replay reports the current snapshot (the folder may have been renamed since).
                if let Some(current) = repository::get(&tx, outcome.folder.id)? {
                    outcome.folder = current;
                }
                tx.commit()?;
                return Ok(outcome);
            }
            Receipt::Fresh(fingerprint) => fingerprint,
        };
        if repository::by_key(&tx, &key)?.is_some() {
            return Err(CoreError::conflict(
                ErrorCode::FolderExists,
                format!("a folder named \u{201c}{name}\u{201d} already exists"),
            ));
        }
        let folder = Folder { id: ids::new_id(), name, created_at_ms: now, updated_at_ms: now, revision: 1 };
        repository::insert(&tx, &folder, &key)?;
        bump_revision(&tx)?;
        let outcome = FolderOutcome { folder, changed: true, replayed: false };
        store_receipt(&tx, request_id, fingerprint.as_deref(), "folder_create", &outcome, now)?;
        tx.commit()?;
        Ok(outcome)
    }

    /// `folder rename NAME NEW_NAME` (0019 §3, §5). The same name is a no-op;
    /// a new name with the folder's own key (`work` → `Work`) only changes the
    /// name; another folder's key is `FOLDER_EXISTS`.
    pub fn rename_folder(
        &mut self,
        folder: &FolderSelector,
        new_name: &str,
        request_id: Option<&str>,
    ) -> CoreResult<FolderOutcome> {
        let (new_name, new_key) = validate_name(new_name)?;
        let now = self.now_ms();
        let tx = self.write_tx()?;
        let inputs = RenameInputs { command: "folder_rename", folder: folder.fingerprint(), name: &new_name };
        let fingerprint = match check_receipt::<FolderOutcome>(&tx, request_id, &inputs)? {
            Receipt::Replay(mut outcome) => {
                outcome.replayed = true;
                // 0003 §7: a replay reports the current snapshot (the folder may have been renamed since).
                if let Some(current) = repository::get(&tx, outcome.folder.id)? {
                    outcome.folder = current;
                }
                tx.commit()?;
                return Ok(outcome);
            }
            Receipt::Fresh(fingerprint) => fingerprint,
        };
        let current = repository::resolve(&tx, folder)?.ok_or_else(|| built_in("renamed"))?;
        let outcome = if current.name == new_name {
            FolderOutcome { folder: current, changed: false, replayed: false }
        } else {
            if let Some(other) = repository::by_key(&tx, &new_key)?
                && other.id != current.id
            {
                return Err(CoreError::conflict(
                    ErrorCode::FolderExists,
                    format!("a folder named \u{201c}{new_name}\u{201d} already exists"),
                ));
            }
            repository::rename(&tx, current.id, &new_name, &new_key, now)?;
            bump_revision(&tx)?;
            let renamed = repository::get(&tx, current.id)?.expect("the folder was just renamed");
            FolderOutcome { folder: renamed, changed: true, replayed: false }
        };
        store_receipt(&tx, request_id, fingerprint.as_deref(), "folder_rename", &outcome, now)?;
        tx.commit()?;
        Ok(outcome)
    }

    /// `folder delete NAME [--keep-notes | --delete-notes]` (0019 §5).
    ///
    /// A folder holds notes when any nondeleted item is in it; then `notes`
    /// must say what to do with them (`FOLDER_NOT_EMPTY` otherwise). Deleting
    /// them goes through the same `soft_delete` as `rallo delete`, so an
    /// active reminder is disabled and its cancel intent queued identically.
    /// Every item in the folder, already-deleted ones too, then leaves it, and
    /// the folder row goes: one transaction, one `change_revision` bump.
    pub fn delete_folder(
        &mut self,
        folder: &FolderSelector,
        notes: Option<DeleteNotes>,
        request_id: Option<&str>,
    ) -> CoreResult<FolderDeleteOutcome> {
        let now = self.now_ms();
        let tx = self.write_tx()?;
        let inputs = DeleteInputs {
            command: "folder_delete",
            folder: folder.fingerprint(),
            notes: notes.map(|notes| match notes {
                DeleteNotes::Keep => "keep",
                DeleteNotes::Delete => "delete",
            }),
        };
        let fingerprint = match check_receipt::<FolderDeleteOutcome>(&tx, request_id, &inputs)? {
            Receipt::Replay(mut outcome) => {
                outcome.replayed = true;
                // 0003 §7: a replay reports the current snapshot (the folder may have been renamed since).
                if let Some(current) = repository::get(&tx, outcome.folder.id)? {
                    outcome.folder = current;
                }
                tx.commit()?;
                return Ok(outcome);
            }
            Receipt::Fresh(fingerprint) => fingerprint,
        };
        let current = repository::resolve(&tx, folder)?.ok_or_else(|| built_in("deleted"))?;
        let held = repository::nondeleted_ids(&tx, current.id)?;
        let (mut moved, mut deleted, mut reminders_cancelled) = (0, 0, 0);
        let disposition = match (held.len(), notes) {
            (0, _) => NotesDisposition::None,
            (count, None) => {
                // A conflict to the FFI (0019 §4); the CLI reports it as exit 2.
                return Err(CoreError::conflict(
                    ErrorCode::FolderNotEmpty,
                    format!(
                        "Folder \u{201c}{}\u{201d} holds {count} note{}: pass --keep-notes or --delete-notes",
                        current.name,
                        if count == 1 { "" } else { "s" }
                    ),
                ));
            }
            (count, Some(DeleteNotes::Keep)) => {
                moved = count as u64;
                NotesDisposition::Kept
            }
            (count, Some(DeleteNotes::Delete)) => {
                for id in &held {
                    let active =
                        reminders::repository::fetch_by_item(&tx, *id)?.is_some_and(|reminder| reminder.enabled);
                    soft_delete(&tx, *id, now)?;
                    reminders_cancelled += u64::from(active);
                }
                deleted = count as u64;
                NotesDisposition::Deleted
            }
        };
        repository::clear_items(&tx, current.id, now)?;
        repository::delete_row(&tx, current.id)?;
        bump_revision(&tx)?;
        let outcome = FolderDeleteOutcome {
            folder: current,
            notes: disposition,
            moved,
            deleted,
            reminders_cancelled,
            replayed: false,
        };
        store_receipt(&tx, request_id, fingerprint.as_deref(), "folder_delete", &outcome, now)?;
        tx.commit()?;
        Ok(outcome)
    }
}
