use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::thread;

use rallo_core::items::{ListFilter, ListQuery};
use rallo_core::preferences::PetVisibility;
use rallo_core::shared::clock::ManualClock;
use rallo_core::storage::database::DATABASE_FILE;
use rallo_core::storage::instance_lock::InstanceLock;
use rallo_core::{CoreError, ErrorCode, Store, StoreOptions};

fn open(dir: &std::path::Path) -> Store {
    Store::open(StoreOptions::new(dir)).expect("store opens")
}

#[test]
fn storage_is_private_durable_wal() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path().join("Razlio/Rallo");
    let store = open(&dir);
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(dir.join(DATABASE_FILE)).unwrap().permissions().mode() & 0o777, 0o600);
    drop(store);

    let conn = rusqlite_check::open(&dir.join(DATABASE_FILE));
    assert_eq!(rusqlite_check::pragma(&conn, "journal_mode"), "wal");
}

#[test]
fn notes_persist_across_reopen_with_revision_bumps() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = Store::open(StoreOptions::new(temp.path()).with_clock(clock.clone())).unwrap();
    assert_eq!(store.change_revision().unwrap(), 0);
    let first = store.create_note("first", None).unwrap().item;
    clock.advance(5);
    let second = store.create_note("second\n  indented", None).unwrap().item;
    assert_eq!(store.change_revision().unwrap(), 2);
    assert_eq!((first.item.created_at_ms, second.item.created_at_ms), (1_000, 1_005));
    drop(store);

    let store = open(temp.path());
    let texts: Vec<_> = store
        .list(ListQuery { filter: ListFilter::Open, limit: 50, cursor: None })
        .unwrap()
        .items
        .into_iter()
        .map(|view| view.item.text)
        .collect();
    assert_eq!(texts, ["second\n  indented", "first"], "newest first, text verbatim");
}

#[test]
fn rejected_input_commits_nothing() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = open(temp.path());
    let error = store.create_note("   \n", None).unwrap_err();
    assert_eq!(error.code(), ErrorCode::TextEmpty);
    assert_eq!(store.change_revision().unwrap(), 0);
    assert!(store.list(ListQuery { filter: ListFilter::Open, limit: 50, cursor: None }).unwrap().items.is_empty());
}

#[test]
fn concurrent_writers_lose_nothing() {
    let temp = tempfile::tempdir().unwrap();
    open(temp.path());
    let writers: Vec<_> = (0..8)
        .map(|writer| {
            let dir = temp.path().to_path_buf();
            thread::spawn(move || {
                let mut store = open(&dir);
                for n in 0..25 {
                    // STORAGE_BUSY is the documented refusal once the 1 s lock
                    // wait elapses (easy on a loaded machine with fullfsync);
                    // nothing was written, so a caller retries.
                    let text = format!("writer {writer} note {n}");
                    loop {
                        match store.create_note(&text, None) {
                            Ok(_) => break,
                            Err(error) if error.code() == ErrorCode::StorageBusy => continue,
                            Err(error) => panic!("unexpected error: {error}"),
                        }
                    }
                }
            })
        })
        .collect();
    writers.into_iter().for_each(|handle| handle.join().unwrap());
    let store = open(temp.path());
    assert_eq!(store.change_revision().unwrap(), 200);
}

#[test]
fn newer_schema_is_refused_without_modification() {
    let temp = tempfile::tempdir().unwrap();
    drop(open(temp.path()));
    let conn = rusqlite_check::open(&temp.path().join(DATABASE_FILE));
    conn.execute_batch("PRAGMA user_version = 42;").unwrap();
    drop(conn);
    match Store::open(StoreOptions::new(temp.path())) {
        Err(CoreError::IncompatibleSchema { found: 42, .. }) => {}
        other => panic!("expected IncompatibleSchema, got {:?}", other.err()),
    }
    let conn = rusqlite_check::open(&temp.path().join(DATABASE_FILE));
    assert_eq!(rusqlite_check::pragma(&conn, "user_version"), "42");
}

#[test]
fn preferences_only_bump_revision_on_change() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = open(temp.path());
    assert_eq!(store.pet_visibility().unwrap(), None);
    assert!(store.set_pet_visibility(PetVisibility::Hidden).unwrap());
    assert!(!store.set_pet_visibility(PetVisibility::Hidden).unwrap());
    assert_eq!(store.change_revision().unwrap(), 1);
    assert!(!store.set_pet_placement(None).unwrap(), "clearing an unset placement is a no-op");
}

#[test]
fn instance_lock_is_exclusive_and_released_on_drop() {
    let temp = tempfile::tempdir().unwrap();
    assert!(!InstanceLock::is_held(temp.path()).unwrap());
    let lock = InstanceLock::try_acquire(temp.path()).unwrap().expect("first acquire");
    assert!(InstanceLock::try_acquire(temp.path()).unwrap().is_none());
    assert!(InstanceLock::is_held(temp.path()).unwrap());
    drop(lock);
    assert!(!InstanceLock::is_held(temp.path()).unwrap());
}

/// Independent raw access for assertions, bypassing the Store API.
mod rusqlite_check {
    pub fn open(path: &std::path::Path) -> rusqlite::Connection {
        rusqlite::Connection::open(path).unwrap()
    }

    pub fn pragma(conn: &rusqlite::Connection, name: &str) -> String {
        conn.query_row(&format!("PRAGMA {name}"), [], |row| row.get::<_, rusqlite::types::Value>(0))
            .map(|value| match value {
                rusqlite::types::Value::Text(text) => text,
                rusqlite::types::Value::Integer(n) => n.to_string(),
                other => format!("{other:?}"),
            })
            .unwrap()
    }
}
