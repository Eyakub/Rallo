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
    assert_eq!(version, 6, "0002 through 0006 must be registered");

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

    // 0003 created agent_sessions; 0004 moved them to the runtime file (0009).
    let agent_tables: u32 = conn
        .query_row("SELECT count(*) FROM sqlite_schema WHERE name = 'agent_sessions'", [], |row| row.get(0))
        .unwrap();
    assert_eq!(agent_tables, 0);

    let backups: Vec<_> = std::fs::read_dir(&backups_dir).unwrap().collect();
    assert_eq!(backups.len(), 1, "exactly one pre-migration backup file");
    assert!(backups[0].as_ref().unwrap().file_name().to_string_lossy().starts_with("pre-migration-v1-"));
}

/// Schema v5, frozen as the five migration files applied in order.
const V1_TO_V5: [&str; 5] = [
    include_str!("../src/storage/sql/0001_initial.sql"),
    include_str!("../src/storage/sql/0002_reminders.sql"),
    include_str!("../src/storage/sql/0003_agent_sessions.sql"),
    include_str!("../src/storage/sql/0004_agent_sessions_to_runtime.sql"),
    include_str!("../src/storage/sql/0005_attachments.sql"),
];

/// Every row of the tables a folder migration must not disturb, as one JSON
/// string per table, so "nothing else changed" is a plain equality.
fn dump(conn: &rusqlite::Connection) -> Vec<String> {
    [
        "SELECT json_group_array(json_array(id, short_key, text, match_key, status, created_at_ms, updated_at_ms,
                                            completed_at_ms, deleted_at_ms, revision))
         FROM (SELECT * FROM items ORDER BY id)",
        "SELECT json_group_array(json_array(id, item_id, deadline_ms, enabled, generation))
         FROM (SELECT * FROM reminders ORDER BY id)",
        "SELECT json_group_array(json_array(id, item_id, file_name, mime_type, byte_size, position))
         FROM (SELECT * FROM attachments ORDER BY id)",
    ]
    .iter()
    .map(|sql| conn.query_row(sql, [], |row| row.get(0)).unwrap())
    .collect()
}

#[test]
fn v5_database_migrates_to_v6_with_every_note_in_notes_and_nothing_else_changed() {
    let temp = tempfile::tempdir().unwrap();
    let mut conn = rusqlite::Connection::open(temp.path().join("rallo.sqlite3")).unwrap();
    for sql in V1_TO_V5 {
        conn.execute_batch(sql).unwrap();
    }
    conn.pragma_update(None, "user_version", 5).unwrap();

    let open_id = rallo_core::shared::ids::new_id().to_string();
    let deleted_id = rallo_core::shared::ids::new_id().to_string();
    for (id, text, deleted_at) in [(&open_id, "an open note", None), (&deleted_id, "a deleted note", Some(1500))] {
        conn.execute(
            "INSERT INTO items (id, short_key, text, match_key, status, created_at_ms, updated_at_ms,
                                completed_at_ms, deleted_at_ms, revision)
             VALUES (?1, ?2, ?3, ?3, 'open', 1000, 1000, NULL, ?4, 1)",
            rusqlite::params![id, id.replace('-', "").to_uppercase(), text, deleted_at],
        )
        .unwrap();
    }
    conn.execute(
        "INSERT INTO reminders (id, item_id, deadline_ms, time_input, input_kind, enabled, generation,
                                created_at_ms, updated_at_ms)
         VALUES ('r1', ?1, 2000, '20m', 'relative', 1, 1, 1000, 1000)",
        [&open_id],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO attachments (id, item_id, file_name, mime_type, byte_size, position, created_at_ms)
         VALUES ('a1', ?1, 'a1.png', 'image/png', 12, 0, 1000)",
        [&open_id],
    )
    .unwrap();
    let before = dump(&conn);

    migrate(&mut conn, &temp.path().join("backups"), 5_000).unwrap();

    let version: u32 = conn.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
    assert_eq!(version, 6);
    assert_eq!(dump(&conn), before, "notes, reminders and images are untouched");
    let filed: i64 =
        conn.query_row("SELECT COUNT(*) FROM items WHERE folder_id IS NOT NULL", [], |row| row.get(0)).unwrap();
    assert_eq!(filed, 0, "every note is in Notes");
    let folders: i64 = conn.query_row("SELECT COUNT(*) FROM folders", [], |row| row.get(0)).unwrap();
    assert_eq!(folders, 0);
    let index: i64 = conn
        .query_row("SELECT COUNT(*) FROM sqlite_schema WHERE name = 'items_open_by_folder'", [], |row| row.get(0))
        .unwrap();
    assert_eq!(index, 1);

    // The new column is a real foreign key.
    conn.pragma_update(None, "foreign_keys", true).unwrap();
    let dangling = conn.execute("UPDATE items SET folder_id = 'no-such-folder' WHERE id = ?1", [&open_id]);
    assert!(dangling.is_err(), "items.folder_id references folders(id)");
}
