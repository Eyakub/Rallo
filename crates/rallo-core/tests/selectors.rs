//! 0003 §6: ID resolution and the display-ID uniqueness extension.
//!
//! `short_key` isn't tied to `id` by any constraint, so these tests insert
//! rows with hand-picked short keys to force exact prefix collisions rather
//! than searching for colliding real UUIDs.

mod support;

use rallo_core::ErrorCode;
use rallo_core::shared::errors::ConflictDetail;
use uuid::Uuid;

fn insert_item(conn: &rusqlite::Connection, id: Uuid, short_key: &str, text: &str) {
    assert_eq!(short_key.len(), 26, "test short keys should look like real ones");
    conn.execute(
        "INSERT INTO items (id, short_key, text, match_key, status, created_at_ms, updated_at_ms,
                            completed_at_ms, deleted_at_ms, revision)
         VALUES (?1, ?2, ?3, ?3, 'open', 1000, 1000, NULL, NULL, 1)",
        rusqlite::params![id.to_string(), short_key, text],
    )
    .unwrap();
}

#[test]
fn colliding_prefixes_are_ambiguous_and_display_ids_lengthen_to_disambiguate() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let conn = support::raw_connection(temp.path());

    let x = Uuid::new_v4();
    let y = Uuid::new_v4();
    let z = Uuid::new_v4();
    let w = Uuid::new_v4();
    insert_item(&conn, x, "AAAAAA00000000000000000000", "item x");
    insert_item(&conn, y, "AAAAAA10000000000000000000", "item y");
    insert_item(&conn, z, "BBBBBB00000000000000000000", "item z");
    insert_item(&conn, w, "0ABCDE00000000000000000000", "item w");

    // A 6-character prefix shared by x and y is ambiguous.
    let error = store.get_item("AAAAAA").unwrap_err();
    assert_eq!(error.code(), ErrorCode::AmbiguousId);
    match error.detail() {
        Some(ConflictDetail::Candidates { total, candidates }) => {
            assert_eq!(*total, 2);
            let ids: Vec<_> = candidates.iter().map(|c| c.item.id).collect();
            assert!(ids.contains(&x) && ids.contains(&y) && !ids.contains(&z));
        }
        other => panic!("expected Candidates detail, got {other:?}"),
    }

    // One extra character disambiguates each of x and y.
    let resolved_x = store.get_item("AAAAAA0").unwrap();
    assert_eq!(resolved_x.item.id, x);
    assert_eq!(resolved_x.display_id, "AAAAAA0", "display id lengthens exactly as far as needed");

    let resolved_y = store.get_item("AAAAAA1").unwrap();
    assert_eq!(resolved_y.item.id, y);
    assert_eq!(resolved_y.display_id, "AAAAAA1");

    // z has no colliding neighbour, so its display id stays the minimum length.
    let resolved_z = store.get_item("BBBBBB").unwrap();
    assert_eq!(resolved_z.item.id, z);
    assert_eq!(resolved_z.display_id, "BBBBBB");

    // Lowercase and Crockford aliases (O -> 0, I/L -> 1) normalize the same
    // way as a manually-typed digit.
    let via_case = store.get_item("aaaaaa").unwrap_err();
    assert_eq!(via_case.code(), ErrorCode::AmbiguousId, "lowercase still collides between x and y");
    let via_alias = store.get_item("oabcde").unwrap().item.id;
    assert_eq!(via_alias, w, "'o' normalizes to '0'");
}

#[test]
fn full_uuid_resolves_exactly_and_includes_deleted_items() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("findable", None).unwrap().item;
    let id = item.item.id;

    assert_eq!(store.get_item(&id.to_string()).unwrap().item.id, id);
    assert_eq!(store.get_item(&id.to_string().to_uppercase()).unwrap().item.id, id, "UUIDs resolve case-insensitively");

    store.delete(&id.to_string(), &Default::default()).unwrap();
    let deleted = store.get_item(&id.to_string()).unwrap();
    assert!(deleted.item.deleted_at_ms.is_some(), "resolution includes deleted items");
}

#[test]
fn short_or_invalid_prefixes_are_rejected_and_unknown_ones_are_not_found() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());

    assert_eq!(store.get_item("abc12").unwrap_err().code(), ErrorCode::InvalidId, "fewer than 6 characters");
    assert_eq!(store.get_item("abc!23").unwrap_err().code(), ErrorCode::InvalidId, "not Base32");
    assert_eq!(store.get_item("zzzzzz").unwrap_err().code(), ErrorCode::ItemNotFound, "no item has this prefix");
}
