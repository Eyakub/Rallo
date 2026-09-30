//! UniFFI bridge between the Rust core and the Swift macOS app.
//!
//! Exposes typed operations only: no SQL, JSON blobs, or UI objects cross this
//! boundary. Generated Swift bindings come from these definitions; never edit
//! them by hand.

mod types;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use rallo_core::items::{ListFilter, ListQuery, MutationOptions};
use rallo_core::shared::signal;
use rallo_core::storage::{instance_lock, migrations, paths};
use rallo_core::{Store, StoreOptions};

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

impl RalloStore {
    fn store(&self) -> MutexGuard<'_, Store> {
        // A panic while holding the lock cannot leave SQLite inconsistent
        // (transactions roll back on drop), so poisoning is not fatal.
        self.inner.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
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
        Ok(self.store().create_note(&text, None)?.item.into())
    }

    pub fn list_open_items(&self, limit: u32) -> Result<Vec<ItemSnapshot>, RalloError> {
        Ok(self
            .store()
            .list(ListQuery { filter: ListFilter::Open, limit, cursor: None })?
            .items
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Marks an item done. `if_revision` guards a snapshot the UI showed;
    /// a changed item fails with `REVISION_CONFLICT` instead of being overwritten.
    pub fn complete_item(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(self.store().complete(&id, &opts)?.item.into())
    }

    /// Replaces an item's text; `if_revision` guards the snapshot being edited.
    pub fn edit_item_text(&self, id: String, text: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(self.store().edit_text(&id, &text, &opts)?.item.into())
    }

    /// Reopens a done item (the panel's undo). Never re-enables a reminder.
    pub fn reopen_item(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError> {
        let opts = MutationOptions { request_id: None, if_revision };
        Ok(self.store().reopen(&id, &opts)?.item.into())
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
}
