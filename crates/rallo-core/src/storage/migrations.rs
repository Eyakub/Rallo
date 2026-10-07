use std::path::Path;

use rusqlite::{Connection, TransactionBehavior};

use super::backup;
use crate::shared::errors::{CoreError, CoreResult};

/// Ordered schema migrations; index + 1 is the resulting `user_version`.
/// Schema v1 stays provisional until the first tagged release.
const MIGRATIONS: &[&str] = &[
    include_str!("sql/0001_initial.sql"),
    include_str!("sql/0002_reminders.sql"),
    include_str!("sql/0003_agent_sessions.sql"),
    include_str!("sql/0004_agent_sessions_to_runtime.sql"),
    include_str!("sql/0005_attachments.sql"),
];

pub const SCHEMA_VERSION: u32 = MIGRATIONS.len() as u32;

fn user_version(conn: &Connection) -> CoreResult<u32> {
    Ok(conn.pragma_query_value(None, "user_version", |row| row.get(0))?)
}

/// Brings the database to `SCHEMA_VERSION` under the SQLite write lock.
/// An existing database is backed up first; newer schemas are refused.
pub fn migrate(conn: &mut Connection, backups_dir: &Path, now_ms: i64) -> CoreResult<()> {
    let found = user_version(conn)?;
    if found > SCHEMA_VERSION {
        return Err(CoreError::IncompatibleSchema { found, supported: SCHEMA_VERSION });
    }
    if found == SCHEMA_VERSION {
        return Ok(());
    }
    if found > 0 {
        backup::snapshot(conn, &backups_dir.join(format!("pre-migration-v{found}-{now_ms}.sqlite3")))?;
    }

    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // Another process may have migrated while we waited for the lock.
    let found = user_version(&tx)?;
    if found > SCHEMA_VERSION {
        return Err(CoreError::IncompatibleSchema { found, supported: SCHEMA_VERSION });
    }
    for sql in &MIGRATIONS[found as usize..] {
        tx.execute_batch(sql)?;
    }
    tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    tx.commit()?;
    Ok(())
}
