use std::fs::{self, DirBuilder, OpenOptions, Permissions};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior};

use super::migrations;
use crate::shared::clock::{Clock, SystemClock};
use crate::shared::errors::{CoreError, CoreResult};

pub const DATABASE_FILE: &str = "rallo.sqlite3";
/// Runtime state (agent sessions, 0009), never backed up or migrated: in
/// `<data dir>/runtime/`, attached to every connection as `runtime`.
pub const RUNTIME_DIR: &str = "runtime";
pub const RUNTIME_FILE: &str = "agents.sqlite3";
pub const BUSY_TIMEOUT: Duration = Duration::from_millis(1000);

pub struct StoreOptions {
    pub data_dir: PathBuf,
    pub clock: Arc<dyn Clock>,
}

impl StoreOptions {
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        Self { data_dir: data_dir.into(), clock: Arc::new(SystemClock) }
    }

    pub fn with_clock(mut self, clock: Arc<dyn Clock>) -> Self {
        self.clock = clock;
        self
    }
}

/// One process's handle to the shared database. Synchronous by design: callers
/// run it on a dedicated worker, never on a UI thread.
pub struct Store {
    conn: Connection,
    data_dir: PathBuf,
    clock: Arc<dyn Clock>,
}

impl Store {
    pub fn open(options: StoreOptions) -> CoreResult<Self> {
        let StoreOptions { data_dir, clock } = options;
        ensure_private_dir(&data_dir)?;
        let data_dir = data_dir.canonicalize()?;
        let path = data_dir.join(DATABASE_FILE);
        // Pre-create with 0600: SQLite gives its -wal/-shm files the same mode.
        OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(&path)?;

        let mut conn = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX | OpenFlags::SQLITE_OPEN_URI,
        )?;
        conn.busy_timeout(BUSY_TIMEOUT)?;
        conn.pragma_update(None, "foreign_keys", true)?;
        crate::items::tags::register(&conn)?;
        conn.pragma_update(None, "synchronous", "FULL")?;
        // macOS fsync() does not flush the drive cache; F_FULLFSYNC does.
        conn.pragma_update(None, "fullfsync", true)?;
        conn.pragma_update(None, "checkpoint_fullfsync", true)?;
        let mode: String = conn.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
        if !mode.eq_ignore_ascii_case("wal") {
            return Err(CoreError::storage(format!("could not enable WAL journaling (got {mode})")));
        }
        migrations::migrate(&mut conn, &data_dir.join("backups"), clock.now_ms())?;
        attach_runtime(&mut conn, &data_dir)?;

        Ok(Self { conn, data_dir, clock })
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn now_ms(&self) -> i64 {
        self.clock.now_ms()
    }

    pub(crate) fn conn(&self) -> &Connection {
        &self.conn
    }

    /// Short write transaction that takes the write lock up front, so busy
    /// waits happen at BEGIN rather than failing mid-transaction.
    pub(crate) fn write_tx(&mut self) -> CoreResult<Transaction<'_>> {
        Ok(self.conn.transaction_with_behavior(TransactionBehavior::Immediate)?)
    }

    /// Cheap monotonic revision used by observers to decide whether to reload.
    pub fn change_revision(&self) -> CoreResult<i64> {
        Ok(self.conn.query_row("SELECT value FROM metadata WHERE key = 'change_revision'", [], |row| row.get(0))?)
    }

    pub fn schema_version(&self) -> CoreResult<u32> {
        Ok(self.conn.pragma_query_value(None, "user_version", |row| row.get(0))?)
    }
}

/// Attaches the runtime database as `runtime`, creating it 0600 inside a
/// 0700 folder. Losing it costs nothing that matters, so durability is
/// relaxed and a layout from another version is simply recreated.
fn attach_runtime(conn: &mut Connection, data_dir: &Path) -> CoreResult<()> {
    let dir = data_dir.join(RUNTIME_DIR);
    ensure_private_dir(&dir)?;
    let path = dir.join(RUNTIME_FILE);
    OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(&path)?;
    let path = path.to_str().ok_or_else(|| CoreError::storage("data directory path is not UTF-8"))?;
    conn.execute("ATTACH DATABASE ?1 AS runtime", [path])?;
    let runtime = Some("runtime");
    let mode: String = conn.pragma_update_and_check(runtime, "journal_mode", "WAL", |row| row.get(0))?;
    if !mode.eq_ignore_ascii_case("wal") {
        return Err(CoreError::storage(format!("could not enable WAL journaling for runtime state (got {mode})")));
    }
    conn.pragma_update(runtime, "synchronous", "NORMAL")?;
    crate::agents::ensure_runtime_schema(conn)
}

/// Bumps the global change revision inside a mutation transaction.
pub(crate) fn bump_revision(tx: &Transaction<'_>) -> CoreResult<i64> {
    Ok(tx.query_row(
        "UPDATE metadata SET value = value + 1 WHERE key = 'change_revision' RETURNING value",
        [],
        |row| row.get(0),
    )?)
}

/// Creates the directory (and parents) if needed; the leaf is user-only.
pub(crate) fn ensure_private_dir(dir: &Path) -> CoreResult<()> {
    if !dir.exists() {
        DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    fs::set_permissions(dir, Permissions::from_mode(0o700))?;
    Ok(())
}
