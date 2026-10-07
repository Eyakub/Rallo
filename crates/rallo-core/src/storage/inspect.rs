//! Read-only inspection for `rallo doctor` (M4). Deliberately independent of
//! `Store::open`, which migrates and writes under the SQLite write lock:
//! doctor must never migrate, never write, and never fail merely because a
//! future build's schema is newer than this one supports. The database is
//! opened `SQLITE_OPEN_READ_ONLY`; an older schema is reported as-is and a
//! newer one can never trigger an accidental write attempt.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use rusqlite::{Connection, OpenFlags, OptionalExtension};

use super::database::DATABASE_FILE;
use crate::shared::errors::CoreResult;

/// One file or directory's permission bits and size, as seen on disk.
#[derive(Debug, Clone)]
pub struct FileStat {
    pub path: PathBuf,
    /// The low 9 permission bits (owner/group/other read/write/execute).
    pub mode: u32,
    pub size_bytes: u64,
}

fn stat(path: &Path) -> Option<FileStat> {
    let meta = fs::metadata(path).ok()?;
    Some(FileStat { path: path.to_path_buf(), mode: meta.permissions().mode() & 0o777, size_bytes: meta.len() })
}

/// `notification_intents` bookkeeping doctor cares about, read directly
/// rather than through `reminders::protocol` (which assumes a fully migrated,
/// writable store).
#[derive(Debug, Clone, Copy, Default)]
pub struct IntentsSummary {
    pub unresolved_count: u32,
    pub oldest_unresolved_created_at_ms: Option<i64>,
    pub abandoned_last_7d_count: u32,
}

/// `<data dir>/backups/`'s contents, independent of whether the live database
/// currently exists (a deleted `rallo.sqlite3` can still be recovered from a
/// snapshot left behind here).
#[derive(Debug, Clone, Default)]
pub struct BackupsSummary {
    pub count: u32,
    pub newest_path: Option<PathBuf>,
    pub newest_modified_ms: Option<i64>,
}

/// Read-only snapshot of one data directory's database. `StoreInspection::open`
/// returns `Ok(None)` when there is no database yet: a fresh install, not a
/// problem.
#[derive(Debug, Clone)]
pub struct StoreInspection {
    pub dir_stat: Option<FileStat>,
    pub db_stat: FileStat,
    pub wal_stat: Option<FileStat>,
    pub shm_stat: Option<FileStat>,
    /// `attachments/` (0018); `None` before the first image.
    pub attachments_stat: Option<FileStat>,
    /// Images listed, their bytes, files no row owns, rows whose file is gone.
    pub images: crate::images::ImageAudit,
    pub schema_version_found: u32,
    /// `"ok"`, or the (semicolon-joined) problems `PRAGMA quick_check` reported.
    pub quick_check: String,
    pub active_reminders: u32,
    pub intents: IntentsSummary,
    /// Raw `notifications.authorization` metadata code (0005); `None` means
    /// the app has never recorded one, distinct from an explicitly observed
    /// `not_determined` (code `0`).
    pub notifications_authorization: Option<i64>,
    pub notifications_authorization_observed_at_ms: Option<i64>,
}

fn table_exists(conn: &Connection, name: &str) -> CoreResult<bool> {
    Ok(conn
        .query_row("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [name], |row| row.get::<_, i64>(0))
        .optional()?
        .is_some())
}

fn read_metadata_i64(conn: &Connection, key: &str) -> CoreResult<Option<i64>> {
    Ok(conn.query_row("SELECT value FROM metadata WHERE key = ?1", [key], |row| row.get(0)).optional()?)
}

fn run_quick_check(conn: &Connection) -> CoreResult<String> {
    let mut problems = Vec::new();
    conn.pragma_query(None, "quick_check", |row| {
        let message: String = row.get(0)?;
        if message != "ok" {
            problems.push(message);
        }
        Ok(())
    })?;
    Ok(if problems.is_empty() { "ok".to_owned() } else { problems.join("; ") })
}

impl StoreInspection {
    /// `Ok(None)` when `<data dir>/rallo.sqlite3` does not exist. Never
    /// creates the data directory, the database, or any file.
    pub fn open(data_dir: &Path, now_ms: i64) -> CoreResult<Option<Self>> {
        let db_path = data_dir.join(DATABASE_FILE);
        if !db_path.is_file() {
            return Ok(None);
        }
        let dir_stat = stat(data_dir);
        let db_stat = stat(&db_path).expect("just confirmed db_path is a file");
        let wal_stat = stat(&PathBuf::from(format!("{}-wal", db_path.display())));
        let shm_stat = stat(&PathBuf::from(format!("{}-shm", db_path.display())));

        let attachments_stat = stat(&data_dir.join(crate::images::ATTACHMENTS_DIR));

        let conn = Connection::open_with_flags(
            &db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX | OpenFlags::SQLITE_OPEN_URI,
        )?;
        let schema_version_found: u32 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        let quick_check = run_quick_check(&conn)?;

        let active_reminders = if table_exists(&conn, "reminders")? {
            conn.query_row("SELECT COUNT(*) FROM reminders WHERE enabled = 1", [], |row| row.get::<_, i64>(0))? as u32
        } else {
            0
        };

        let intents = if table_exists(&conn, "notification_intents")? {
            let unresolved_count: i64 = conn.query_row(
                "SELECT COUNT(*) FROM notification_intents WHERE state IN ('pending', 'attempting')",
                [],
                |row| row.get(0),
            )?;
            let oldest_unresolved_created_at_ms: Option<i64> = conn.query_row(
                "SELECT MIN(created_at_ms) FROM notification_intents WHERE state IN ('pending', 'attempting')",
                [],
                |row| row.get(0),
            )?;
            let seven_days_ago_ms = now_ms - 7 * 24 * 60 * 60 * 1000;
            let abandoned_last_7d_count: i64 = conn.query_row(
                "SELECT COUNT(*) FROM notification_intents WHERE state = 'abandoned' AND resolved_at_ms >= ?1",
                [seven_days_ago_ms],
                |row| row.get(0),
            )?;
            IntentsSummary {
                unresolved_count: unresolved_count as u32,
                oldest_unresolved_created_at_ms,
                abandoned_last_7d_count: abandoned_last_7d_count as u32,
            }
        } else {
            IntentsSummary::default()
        };

        let images = crate::images::audit(&conn, data_dir)?;
        let notifications_authorization = read_metadata_i64(&conn, "notifications.authorization")?;
        let notifications_authorization_observed_at_ms =
            read_metadata_i64(&conn, "notifications.authorization_observed_at_ms")?;

        Ok(Some(Self {
            dir_stat,
            db_stat,
            wal_stat,
            shm_stat,
            attachments_stat,
            images,
            schema_version_found,
            quick_check,
            active_reminders,
            intents,
            notifications_authorization,
            notifications_authorization_observed_at_ms,
        }))
    }
}

/// `<data dir>/backups/`'s contents. A missing directory is "none yet", not
/// an error.
pub fn inspect_backups(backups_dir: &Path) -> BackupsSummary {
    let Ok(entries) = fs::read_dir(backups_dir) else {
        return BackupsSummary::default();
    };
    let mut count = 0u32;
    let mut newest: Option<(PathBuf, i64)> = None;
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        count += 1;
        if let Ok(modified) = meta.modified()
            && let Ok(since_epoch) = modified.duration_since(UNIX_EPOCH)
        {
            let modified_ms = since_epoch.as_millis() as i64;
            if newest.as_ref().is_none_or(|(_, existing)| modified_ms > *existing) {
                newest = Some((path, modified_ms));
            }
        }
    }
    BackupsSummary {
        count,
        newest_path: newest.as_ref().map(|(path, _)| path.clone()),
        newest_modified_ms: newest.map(|(_, at)| at),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use rusqlite::Connection;

    use super::*;
    use crate::storage::database::{Store, StoreOptions, ensure_private_dir};
    use crate::storage::migrations::SCHEMA_VERSION;

    #[test]
    fn no_database_yet_is_none() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().join("fresh");
        assert!(StoreInspection::open(&data_dir, 0).unwrap().is_none());
        assert!(!data_dir.exists(), "inspecting a fresh directory must not create it");
    }

    #[test]
    fn healthy_store_reports_schema_and_quick_check_ok() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().join("data");
        let _store = Store::open(StoreOptions::new(&data_dir)).unwrap();

        let inspection = StoreInspection::open(&data_dir, 0).unwrap().unwrap();
        assert_eq!(inspection.schema_version_found, SCHEMA_VERSION);
        assert_eq!(inspection.quick_check, "ok");
        assert_eq!(inspection.active_reminders, 0);
        assert_eq!(inspection.intents.unresolved_count, 0);
        assert!(inspection.notifications_authorization.is_none());
    }

    #[test]
    fn bad_permissions_are_detected() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().join("data");
        let _store = Store::open(StoreOptions::new(&data_dir)).unwrap();

        let db_path = data_dir.join(DATABASE_FILE);
        fs::set_permissions(&db_path, fs::Permissions::from_mode(0o644)).unwrap();

        let inspection = StoreInspection::open(&data_dir, 0).unwrap().unwrap();
        assert_eq!(inspection.db_stat.mode, 0o644);
        assert_ne!(inspection.db_stat.mode & 0o077, 0, "group/other bits are set");
    }

    #[test]
    fn older_schema_is_reported_and_never_migrated() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().join("data");
        ensure_private_dir(&data_dir).unwrap();
        let db_path = data_dir.join(DATABASE_FILE);
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(include_str!("sql/0001_initial.sql")).unwrap();
        conn.pragma_update(None, "user_version", 1).unwrap();
        drop(conn);

        let inspection = StoreInspection::open(&data_dir, 0).unwrap().unwrap();
        assert_eq!(inspection.schema_version_found, 1);
        assert!(inspection.schema_version_found < SCHEMA_VERSION);
        assert_eq!(inspection.active_reminders, 0, "v1 has no reminders table yet");

        // Re-reading (read-only) never migrates it.
        let again = StoreInspection::open(&data_dir, 0).unwrap().unwrap();
        assert_eq!(again.schema_version_found, 1);
        let raw = Connection::open_with_flags(&db_path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        let version: u32 = raw.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
        assert_eq!(version, 1, "doctor's inspection must never write user_version");
    }

    #[test]
    fn newer_schema_is_reported_without_error() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().join("data");
        {
            let _store = Store::open(StoreOptions::new(&data_dir)).unwrap();
        }
        let db_path = data_dir.join(DATABASE_FILE);
        let conn = Connection::open(&db_path).unwrap();
        conn.pragma_update(None, "user_version", SCHEMA_VERSION + 1).unwrap();
        drop(conn);

        let inspection = StoreInspection::open(&data_dir, 0).unwrap().unwrap();
        assert_eq!(inspection.schema_version_found, SCHEMA_VERSION + 1);
    }

    #[test]
    fn unresolved_intent_age_and_abandoned_history_are_reported() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().join("data");
        let mut store = Store::open(StoreOptions::new(&data_dir)).unwrap();
        let outcome =
            store.create_reminder("check the oven", &crate::reminders::TimeSpec::In("1h".into()), None).unwrap();
        let reminder_id = outcome.item.reminder.unwrap().id;

        // Backdate the schedule intent so it reads as five minutes old.
        let conn = Connection::open(data_dir.join(DATABASE_FILE)).unwrap();
        conn.execute(
            "UPDATE notification_intents SET created_at_ms = created_at_ms - 400000 WHERE reminder_id = ?1",
            [reminder_id.to_string()],
        )
        .unwrap();
        let now_ms = store.now_ms();
        conn.execute(
            "INSERT INTO notification_intents (reminder_id, generation, kind, state, created_at_ms, attempt_count, resolved_at_ms)
             VALUES (?1, 0, 'schedule', 'abandoned', 0, 1, ?2)",
            rusqlite::params![reminder_id.to_string(), now_ms - 1_000],
        )
        .unwrap();
        drop(conn);

        let inspection = StoreInspection::open(&data_dir, now_ms).unwrap().unwrap();
        assert_eq!(inspection.intents.unresolved_count, 1);
        assert!(inspection.intents.oldest_unresolved_created_at_ms.is_some());
        assert_eq!(inspection.intents.abandoned_last_7d_count, 1);
    }

    #[test]
    fn backups_directory_reports_none_yet_when_missing() {
        let dir = tempfile::tempdir().unwrap();
        let summary = inspect_backups(&dir.path().join("backups"));
        assert_eq!(summary.count, 0);
        assert!(summary.newest_path.is_none());
    }

    #[test]
    fn backups_directory_reports_count_and_newest() {
        let dir = tempfile::tempdir().unwrap();
        let backups = dir.path().join("backups");
        fs::create_dir_all(&backups).unwrap();
        fs::write(backups.join("a.sqlite3"), b"a").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        fs::write(backups.join("b.sqlite3"), b"b").unwrap();

        let summary = inspect_backups(&backups);
        assert_eq!(summary.count, 2);
        assert_eq!(summary.newest_path.unwrap(), backups.join("b.sqlite3"));
    }
}
