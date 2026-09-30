//! Migration path from a v1 (M0) database to the current schema.

use rallo_core::storage::migrations::{SCHEMA_VERSION, migrate};

/// The v1 schema, frozen here rather than imported: migrations must keep
/// working against whatever v1 databases already exist in the wild, even
/// after 0001_initial.sql itself changes.
const V1_SQL: &str = include_str!("../src/storage/sql/0001_initial.sql");

#[test]
fn v1_database_migrates_to_current_schema_keeps_data_and_backs_up() {
    let temp = tempfile::tempdir().unwrap();
    let mut conn = rusqlite::Connection::open(temp.path().join("rallo.sqlite3")).unwrap();
    conn.execute_batch(V1_SQL).unwrap();

    let id = rallo_core::shared::ids::new_id();
    let short_key = rallo_core::shared::ids::short_key(&id);
    conn.execute(
        "INSERT INTO items (id, short_key, text, match_key, status, created_at_ms, updated_at_ms,
                            completed_at_ms, deleted_at_ms, revision)
         VALUES (?1, ?2, 'a v1 item', 'a v1 item', 'open', 1000, 1000, NULL, NULL, 1)",
        rusqlite::params![id.to_string(), short_key],
    )
    .unwrap();
    conn.pragma_update(None, "user_version", 1).unwrap();

    let backups_dir = temp.path().join("backups");
    migrate(&mut conn, &backups_dir, 5_000).unwrap();

    let version: u32 = conn.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
    assert_eq!(version, SCHEMA_VERSION);
    assert_eq!(version, 2, "0002_reminders.sql must be registered");

    let text: String =
        conn.query_row("SELECT text FROM items WHERE id = ?1", [id.to_string()], |row| row.get(0)).unwrap();
    assert_eq!(text, "a v1 item", "existing data survives the migration");

    // The new tables exist and are usable.
    conn.execute(
        "INSERT INTO reminders (id, item_id, deadline_ms, time_input, input_kind, enabled, generation,
                                created_at_ms, updated_at_ms)
         VALUES ('r1', ?1, 2000, '20m', 'relative', 1, 1, 1000, 1000)",
        [id.to_string()],
    )
    .unwrap();

    let backups: Vec<_> = std::fs::read_dir(&backups_dir).unwrap().collect();
    assert_eq!(backups.len(), 1, "exactly one pre-migration backup file");
    assert!(backups[0].as_ref().unwrap().file_name().to_string_lossy().starts_with("pre-migration-v1-"));
}
