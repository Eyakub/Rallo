//! UniFFI bridge between the Rust core and the Swift macOS app.
//!
//! Exposes typed operations only: no SQL, JSON blobs, or UI objects cross this
//! boundary. Generated Swift bindings come from these definitions; never edit
//! them by hand.

mod types;

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use rallo_core::items::{ItemView, ListFilter, ListQuery, MutationOptions, MutationOutcome};
use rallo_core::pet;
use rallo_core::reminders::phrase;
use rallo_core::reminders::protocol as core_protocol;
use rallo_core::reminders::time::deadline_ms;
use rallo_core::reminders::{SchedulingStatus, TimeSpec};
use rallo_core::shared::signal;
use rallo_core::storage::{instance_lock, migrations, paths};
use rallo_core::transfer::MAX_IMPORT_BYTES;
use rallo_core::{ErrorCode, Store, StoreOptions};
use rallo_platform_macos::{archive, local_time};

pub use types::*;

uniffi::setup_scaffolding!();

#[uniffi::export]
pub fn core_info() -> CoreInfo {
    CoreInfo {
        core_version: rallo_core::CORE_VERSION.to_owned(),
        schema_version: migrations::SCHEMA_VERSION,
        json_contract_version: rallo_core::JSON_CONTRACT_VERSION,
    }
}

/// Pure priority-table reducer (plan §2; 0006). No store access: callers pass
/// a `PetSnapshot` from `RalloStore::petSnapshot`.
#[uniffi::export]
pub fn decide_pet(inputs: PetInputs) -> PetDecision {
    pet::decide(&inputs.into()).into()
}

/// Explicit path > `RALLO_DATA_DIR` > the default Application Support path.
#[uniffi::export]
pub fn resolve_data_dir(explicit: Option<String>) -> Result<String, RalloError> {
    let path = paths::resolve_data_dir(explicit.as_deref().map(Path::new))?;
    Ok(path.to_string_lossy().into_owned())
}

#[uniffi::export]
pub fn change_signal_name(data_dir: String) -> String {
    signal::change_signal_name(Path::new(&data_dir))
}

#[uniffi::export]
pub fn show_signal_name(data_dir: String) -> String {
    signal::show_signal_name(Path::new(&data_dir))
}

/// The deadline (UTC ms) that `text` -- RFC 3339 or a 0016 phrase such as
/// "fri 5pm" -- resolves to at `now_ms`, for the panel's live preview: the
/// same rules `rallo remind --at` applies. Writes nothing.
#[uniffi::export]
pub fn resolve_reminder_time(text: String, now_ms: i64) -> Result<i64, RalloError> {
    let spec = phrase::time_spec(&text, now_ms, local_time::wall_clock, local_time::instant)?;
    Ok(deadline_ms(&spec, now_ms)?)
}

#[uniffi::export]
pub fn diagnostics_signal_name(data_dir: String) -> String {
    signal::diagnostics_signal_name(Path::new(&data_dir))
}

/// Holds the single-instance/drainer lock for as long as the object lives.
#[derive(uniffi::Object)]
pub struct InstanceLock {
    _lock: instance_lock::InstanceLock,
}

/// Returns `None` when another app instance owns this data directory.
#[uniffi::export]
pub fn try_acquire_instance_lock(data_dir: String) -> Result<Option<Arc<InstanceLock>>, RalloError> {
    let lock = instance_lock::InstanceLock::try_acquire(Path::new(&data_dir))?;
    Ok(lock.map(|lock| Arc::new(InstanceLock { _lock: lock })))
}

/// Store handle for the app. Calls are synchronous; Swift runs them on a
/// dedicated serial worker, never the main thread.
#[derive(uniffi::Object)]
pub struct RalloStore {
    inner: Mutex<Store>,
}

/// Whether `path` is a zip export (by its first bytes).
fn is_archive(path: &str) -> Result<bool, RalloError> {
    archive::is_zip(Path::new(path)).map_err(|error| RalloError::InvalidInput {
        code: "INVALID_INPUT".into(),
        message: format!("could not read {path}: {error}"),
    })
}

/// Reads one byte past the cap so the core reports an oversized file with
/// its documented message instead of silently truncating it.
fn read_import_file(path: &str) -> Result<Vec<u8>, RalloError> {
    let unreadable = |error: std::io::Error| RalloError::InvalidInput {
        code: "INVALID_INPUT".into(),
        message: format!("could not read {path}: {error}"),
    };
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(unreadable)?
        .take(MAX_IMPORT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(unreadable)?;
    Ok(bytes)
}

fn with_scheduling(mut snapshot: ItemSnapshot, scheduling: Option<SchedulingStatus>) -> ItemSnapshot {
    if let (Some(reminder), Some(status)) = (snapshot.reminder.as_mut(), scheduling) {
        reminder.scheduling_state = Some(status.state.to_owned());
        reminder.scheduling_reason = Some(status.reason.to_owned());
    }
    snapshot
}

fn from_outcome(outcome: MutationOutcome) -> ItemSnapshot {
    let scheduling = outcome.scheduling;
    with_scheduling(outcome.item.into(), scheduling)
}

fn from_view(store: &Store, view: ItemView) -> Result<ItemSnapshot, RalloError> {
    let scheduling = store.scheduling_status(&view)?;
    Ok(with_scheduling(view.into(), scheduling))
}

impl RalloStore {
    fn store(&self) -> MutexGuard<'_, Store> {
        // A panic while holding the lock cannot leave SQLite inconsistent
        // (transactions roll back on drop), so poisoning is not fatal.
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Drops agent sessions whose process has gone or that sat idle for 24 h;
/// returns the `now_ms` it used.
fn prune_agent_sessions(store: &mut Store) -> Result<i64, RalloError> {
    let now_ms = store.now_ms();
    store.prune_agent_sessions(now_ms, &|p| rallo_platform_macos::process_ancestry::is_alive(p.pid, p.started_us))?;
    Ok(now_ms)
}

#[uniffi::export]
impl RalloStore {
    #[uniffi::constructor]
    pub fn open(data_dir: String) -> Result<Arc<Self>, RalloError> {
        let store = Store::open(StoreOptions::new(PathBuf::from(data_dir)))?;
        Ok(Arc::new(Self { inner: Mutex::new(store) }))
    }

    pub fn data_dir(&self) -> String {
        self.store().data_dir().to_string_lossy().into_owned()
    }

    pub fn change_revision(&self) -> Result<i64, RalloError> {
        Ok(self.store().change_revision()?)
    }

    pub fn create_note(&self, text: String) -> Result<ItemSnapshot, RalloError> {
        self.create_note_with_images(text, Vec::new())
    }

    /// A note with images (0018); `text` may be empty when there are images.
    pub fn create_note_with_images(&self, text: String, images: Vec<Vec<u8>>) -> Result<ItemSnapshot, RalloError> {
        Ok(from_outcome(self.store().create_note_with_images(&text, &images, None)?))
    }

    /// A note and its reminder in one write, as `rallo remind TEXT --at WHEN`
    /// (0017): `when` is RFC 3339 or a 0016 phrase such as "fri 5pm".
    pub fn create_reminder(&self, text: String, when: String) -> Result<ItemSnapshot, RalloError> {
        self.create_reminder_with_images(text, when, Vec::new())
    }

    pub fn create_reminder_with_images(
        &self,
        text: String,
        when: String,
        images: Vec<Vec<u8>>,
    ) -> Result<ItemSnapshot, RalloError> {
        let mut store = self.store();
        let spec = phrase::time_spec(&when, store.now_ms(), local_time::wall_clock, local_time::instant)?;
        Ok(from_outcome(store.create_reminder_with_images(&text, &spec, &images, None)?))
    }

    pub fn attach_images(
        &self,
        id: String,
        images: Vec<Vec<u8>>,
        if_revision: Option<i64>,
    ) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().attach_images(&id, &images, &opts)?))
    }

    pub fn detach_image(
        &self,
        id: String,
        image_id: String,
        if_revision: Option<i64>,
    ) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().detach_image(&id, &image_id, &opts)?))
    }

    /// Removes images of notes deleted 30+ days ago and stray files (0018);
    /// the app runs it at launch and once a day.
    pub fn sweep_images(&self) -> Result<SweepResult, RalloError> {
        Ok(self.store().sweep_images()?.into())
    }

    pub fn list_open_items(&self, limit: u32) -> Result<Vec<ItemSnapshot>, RalloError> {
        let store = self.store();
        let page = store.list(ListQuery { filter: ListFilter::Open, limit, cursor: None })?;
        page.items.into_iter().map(|view| from_view(&store, view)).collect()
    }

    /// Writes a JSON backup, CSV or zip archive atomically with mode 0600;
    /// refuses to replace an existing file unless `overwrite`.
    pub fn export_to_file(
        &self,
        path: String,
        format: TransferFormat,
        overwrite: bool,
    ) -> Result<ExportResult, RalloError> {
        let store = self.store();
        let path = Path::new(&path);
        let summary = match format.plain() {
            Some(plain) => store.export_to_file(path, plain, overwrite)?,
            None => {
                rallo_core::transfer::export::refuse_existing(path, overwrite)?;
                archive::write_zip(path, |dir| -> Result<_, RalloError> { Ok(store.export_to_dir(dir)?) })?
            }
        };
        Ok(ExportResult { items: summary.items, path: path.display().to_string(), warnings: summary.warnings })
    }

    /// Validates and classifies a file without writing anything. Conflicts
    /// are reported in the summary for review, not thrown.
    pub fn preview_import_file(&self, path: String) -> Result<ImportSummary, RalloError> {
        if is_archive(&path)? {
            let report = archive::read_zip(Path::new(&path), |dir| -> Result<_, RalloError> {
                Ok(self.store().inspect_import_dir(dir)?)
            })?;
            return Ok(ImportSummary { format: TransferFormat::Zip, ..ImportSummary::from(report) });
        }
        let bytes = read_import_file(&path)?;
        Ok(self.store().inspect_import(&bytes)?.into())
    }

    /// Imports atomically after a pre-import snapshot; any conflict aborts
    /// before anything is written.
    pub fn apply_import_file(&self, path: String) -> Result<ImportSummary, RalloError> {
        if is_archive(&path)? {
            let report = archive::read_zip(Path::new(&path), |dir| -> Result<_, RalloError> {
                Ok(self.store().apply_import_dir(dir)?)
            })?;
            return Ok(ImportSummary { format: TransferFormat::Zip, ..ImportSummary::from(report) });
        }
        let bytes = read_import_file(&path)?;
        Ok(self.store().apply_import(&bytes)?.into())
    }

    /// Soft-deletes an item; `restore_item` undoes it (never re-enabling a reminder).
    pub fn delete_item(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().delete(&id, &opts)?))
    }

    pub fn restore_item(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().restore(&id, &opts)?))
    }

    /// Sets (or moves) the item's reminder to now + `duration` (`--in` syntax, e.g. "20m").
    pub fn remind_in(
        &self,
        id: String,
        duration: String,
        if_revision: Option<i64>,
    ) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().reschedule(&id, &TimeSpec::In(duration), &opts)?))
    }

    /// Sets the item's reminder to an RFC 3339 instant with an explicit offset.
    pub fn remind_at(&self, id: String, rfc3339: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().reschedule(&id, &TimeSpec::At(rfc3339), &opts)?))
    }

    /// Marks an item done. `if_revision` guards a snapshot the UI showed;
    /// a changed item fails with `REVISION_CONFLICT` instead of being overwritten.
    pub fn complete_item(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().complete(&id, &opts)?))
    }

    /// Replaces an item's text; `if_revision` guards the snapshot being edited.
    pub fn edit_item_text(
        &self,
        id: String,
        text: String,
        if_revision: Option<i64>,
    ) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().edit_text(&id, &text, &opts)?))
    }

    /// Reopens a done item (the panel's undo). Never re-enables a reminder.
    pub fn reopen_item(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().reopen(&id, &opts)?))
    }

    /// Requires a reminder. An active reminder is disabled `acknowledged`
    /// with a cancel intent; an already-inactive one is a no-op.
    pub fn acknowledge_reminder(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().acknowledge(&id, &opts)?))
    }

    /// `--in` syntax only; requires an existing reminder on an open,
    /// nondeleted item.
    pub fn snooze_reminder(
        &self,
        id: String,
        duration: String,
        if_revision: Option<i64>,
    ) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(from_outcome(self.store().snooze(&id, &duration, &opts)?))
    }

    /// Projection for `decide_pet`'s `PetInputs.snapshot`. Prunes agent
    /// sessions whose process has gone first (0009), so a closed terminal
    /// stops the pet asking for attention.
    pub fn pet_snapshot(&self) -> Result<PetSnapshot, RalloError> {
        let mut store = self.store();
        prune_agent_sessions(&mut store)?;
        Ok(store.pet_snapshot()?.into())
    }

    /// Fresh `waiting` agent sessions whose process is still running, most
    /// recent first, for the panel's "Agents" section (0007, 0009).
    pub fn agent_sessions(&self) -> Result<Vec<AgentSessionSnapshot>, RalloError> {
        let mut store = self.store();
        let now_ms = prune_agent_sessions(&mut store)?;
        Ok(store.agent_sessions(now_ms)?.into_iter().map(Into::into).collect())
    }

    /// Replaces the ClickUp rows with the conversations now waiting on the
    /// user (0010); `Ok(true)` when anything changed. An empty list clears them.
    pub fn sync_clickup_waiting(&self, items: Vec<ExternalWaitingInput>) -> Result<bool, RalloError> {
        let items: Vec<_> = items.into_iter().map(Into::into).collect();
        Ok(self.store().sync_external_waiting(rallo_core::agents::AgentKind::ClickUp, &items)?)
    }

    /// Removes one tracked session (the panel's ✕). `true` if it existed.
    pub fn dismiss_agent_session(&self, agent: String, session_id: String) -> Result<bool, RalloError> {
        let agent = rallo_core::agents::AgentKind::parse(&agent).ok_or_else(|| RalloError::InvalidInput {
            code: ErrorCode::InvalidInput.as_str().to_owned(),
            message: format!("unknown agent \"{agent}\""),
        })?;
        Ok(self.store().dismiss_agent_session(agent, &session_id)?)
    }

    pub fn pet_animations_paused(&self) -> Result<bool, RalloError> {
        Ok(self.store().pet_animations_paused()?)
    }

    pub fn set_pet_animations_paused(&self, paused: bool) -> Result<bool, RalloError> {
        Ok(self.store().set_pet_animations_paused(paused)?)
    }

    /// Menu-bar "Notify When an Agent Waits 5 Minutes" (0008).
    pub fn agents_notify_long_wait(&self) -> Result<bool, RalloError> {
        Ok(self.store().agents_notify_long_wait()?)
    }

    pub fn set_agents_notify_long_wait(&self, enabled: bool) -> Result<bool, RalloError> {
        Ok(self.store().set_agents_notify_long_wait(enabled)?)
    }

    pub fn pet_visibility(&self) -> Result<Option<PetVisibility>, RalloError> {
        Ok(self.store().pet_visibility()?.map(Into::into))
    }

    pub fn set_pet_visibility(&self, visibility: PetVisibility) -> Result<bool, RalloError> {
        Ok(self.store().set_pet_visibility(visibility.into())?)
    }

    pub fn pet_placement(&self) -> Result<Option<PetPlacement>, RalloError> {
        Ok(self.store().pet_placement()?.map(Into::into))
    }

    pub fn set_pet_placement(&self, placement: Option<PetPlacement>) -> Result<bool, RalloError> {
        Ok(self.store().set_pet_placement(placement.map(Into::into))?)
    }

    pub fn onboarding_completed(&self) -> Result<bool, RalloError> {
        Ok(self.store().onboarding_completed()?)
    }

    pub fn set_onboarding_completed(&self) -> Result<bool, RalloError> {
        Ok(self.store().set_onboarding_completed()?)
    }

    /// This store's identifier prefix (`rallo.reminder.<scope>.`); Swift
    /// filters `UNUserNotificationCenter` requests down to it before
    /// reporting them to `record_native_observations`.
    pub fn notification_identifier_prefix(&self) -> String {
        self.store().notification_prefix()
    }

    pub fn notification_authorization(&self) -> Result<NotificationAuthorization, RalloError> {
        Ok(self.store().notification_authorization()?.into())
    }

    pub fn record_native_observations(
        &self,
        authorization: NotificationAuthorization,
        pending: Vec<NativeRequest>,
        delivered: Vec<NativeRequest>,
    ) -> Result<CleanupPlan, RalloError> {
        let pending: Vec<core_protocol::NativeRequest> = pending.into_iter().map(Into::into).collect();
        let delivered: Vec<core_protocol::NativeRequest> = delivered.into_iter().map(Into::into).collect();
        Ok(self.store().record_native_observations(authorization.into(), &pending, &delivered)?.into())
    }

    pub fn next_platform_work(&self) -> Result<NextWork, RalloError> {
        Ok(self.store().next_platform_work()?.into())
    }

    pub fn begin_platform_attempt(&self, intent_id: i64, generation: i64) -> Result<BeginOutcome, RalloError> {
        Ok(self.store().begin_platform_attempt(intent_id, generation)?.into())
    }

    pub fn finish_platform_attempt(&self, token: AttemptToken, outcome: NativeOutcome) -> Result<Finished, RalloError> {
        Ok(self.store().finish_platform_attempt(token.into(), outcome.into())?.into())
    }

    /// A tapped notification action. Applies only if `generation` is still
    /// current, the reminder enabled, and the item not deleted; otherwise the
    /// current item (if any) comes back as `ActionOutcome::Stale`.
    pub fn apply_notification_action(
        &self,
        reminder_id: String,
        generation: i64,
        action: NotificationAction,
    ) -> Result<ActionOutcome, RalloError> {
        let reminder_id = uuid::Uuid::parse_str(&reminder_id).map_err(|_| RalloError::InvalidInput {
            code: ErrorCode::InvalidId.as_str().to_owned(),
            message: "reminder id must be a UUID".to_owned(),
        })?;
        let mut store = self.store();
        match store.apply_notification_action(reminder_id, generation, action.into())? {
            core_protocol::ActionOutcome::Applied(view) => Ok(ActionOutcome::Applied(from_view(&store, view)?)),
            core_protocol::ActionOutcome::Stale { item, reason } => {
                let item = item.map(|view| from_view(&store, view)).transpose()?;
                Ok(ActionOutcome::Stale { item, reason: reason.into() })
            }
        }
    }
}
