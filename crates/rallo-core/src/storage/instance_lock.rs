use std::fs::{File, OpenOptions, TryLockError};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use super::database::ensure_private_dir;
use crate::shared::errors::CoreResult;

const LOCK_FILE: &str = "app.lock";

/// OS-managed advisory lock (flock) marking the single app instance and
/// notification drainer for one data directory. Released by the kernel when
/// the holder exits or crashes, unlike a PID file.
#[derive(Debug)]
pub struct InstanceLock {
    _file: File,
}

fn open_lock_file(data_dir: &Path) -> CoreResult<File> {
    ensure_private_dir(data_dir)?;
    Ok(OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(data_dir.join(LOCK_FILE))?)
}

impl InstanceLock {
    /// Returns `None` when another process holds the lock.
    pub fn try_acquire(data_dir: &Path) -> CoreResult<Option<Self>> {
        let file = open_lock_file(data_dir)?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Self { _file: file })),
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Error(error)) => Err(error.into()),
        }
    }

    /// Whether an app instance currently holds the lock. The probe holds the
    /// lock for an instant, so the app retries acquisition briefly at launch.
    pub fn is_held(data_dir: &Path) -> CoreResult<bool> {
        let file = open_lock_file(data_dir)?;
        match file.try_lock() {
            Ok(()) => Ok(false),
            Err(TryLockError::WouldBlock) => Ok(true),
            Err(TryLockError::Error(error)) => Err(error.into()),
        }
    }
}
