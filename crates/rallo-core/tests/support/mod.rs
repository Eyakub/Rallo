//! Shared integration-test helpers. Not a test binary itself: Cargo only
//! treats `tests/<name>.rs` files as targets, so nested `mod.rs` files are
//! safe to `mod support;` from multiple test files without duplication.
//!
//! Each test binary compiles this module separately and only uses a subset
//! of it.
#![allow(dead_code)]

use std::path::Path;

use rallo_core::storage::database::DATABASE_FILE;
use rallo_core::{Store, StoreOptions};
use uuid::Uuid;

pub fn open(dir: &Path) -> Store {
    Store::open(StoreOptions::new(dir)).expect("store opens")
}

/// A second, independent connection to the same database file, for setting up
/// state the mutation API cannot yet create (reminder creation is part B).
pub fn raw_connection(dir: &Path) -> rusqlite::Connection {
    rusqlite::Connection::open(dir.join(DATABASE_FILE)).expect("raw connection opens")
}

/// Inserts an active (enabled) reminder for `item_id` with a matching pending
/// `schedule` intent at generation 1, as `remind`/`reschedule` will once part
/// B lands.
pub fn insert_active_reminder(dir: &Path, item_id: Uuid, deadline_ms: i64, now_ms: i64) {
    let conn = raw_connection(dir);
    let reminder_id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO reminders (id, item_id, deadline_ms, time_input, input_kind, enabled, generation,
                                created_at_ms, updated_at_ms)
         VALUES (?1, ?2, ?3, '20m', 'relative', 1, 1, ?4, ?4)",
        rusqlite::params![reminder_id, item_id.to_string(), deadline_ms, now_ms],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO notification_intents (reminder_id, generation, kind, state, created_at_ms, attempt_count)
         VALUES (?1, 1, 'schedule', 'pending', ?2, 0)",
        rusqlite::params![reminder_id, now_ms],
    )
    .unwrap();
}
