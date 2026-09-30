//! 0003 §10: listing filters, search, and pagination.

mod support;

use std::collections::HashSet;
use std::sync::Arc;

use rallo_core::items::{ListFilter, ListQuery, SearchQuery};
use rallo_core::shared::clock::{Clock, ManualClock};
use rallo_core::{ErrorCode, Store, StoreOptions};
use uuid::Uuid;

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

#[test]
fn pagination_total_count_is_limit_independent_and_cursors_cover_everything_once() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let mut created = HashSet::new();
    for n in 0..25 {
        let item = store.create_note(&format!("item {n}"), None).unwrap().item;
        created.insert(item.item.id);
    }

    let full_count = store.list(ListQuery { filter: ListFilter::Open, limit: 200, cursor: None }).unwrap().total_count;
    assert_eq!(full_count, 25);
    let small_page_count =
        store.list(ListQuery { filter: ListFilter::Open, limit: 4, cursor: None }).unwrap().total_count;
    assert_eq!(small_page_count, 25, "total_count does not depend on the page size");

    let mut seen = HashSet::new();
    let mut cursor = None;
    loop {
        let page = store.list(ListQuery { filter: ListFilter::Open, limit: 4, cursor: cursor.clone() }).unwrap();
        assert!(page.items.len() <= 4);
        for view in &page.items {
            assert!(seen.insert(view.item.id), "item {} appeared on more than one page", view.item.id);
        }
        cursor = page.next_cursor;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(seen, created, "every item is covered exactly once across pages");
}

#[test]
fn malformed_cursor_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let error =
        store.list(ListQuery { filter: ListFilter::Open, limit: 10, cursor: Some("not-hex!".into()) }).unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidInput);
}

#[test]
fn limit_outside_one_to_two_hundred_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    assert_eq!(
        store.list(ListQuery { filter: ListFilter::Open, limit: 0, cursor: None }).unwrap_err().code(),
        ErrorCode::InvalidInput
    );
    assert_eq!(
        store.list(ListQuery { filter: ListFilter::Open, limit: 201, cursor: None }).unwrap_err().code(),
        ErrorCode::InvalidInput
    );
}

#[test]
fn search_exact_zero_one_and_multiple_matches() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());

    let none = store
        .search(SearchQuery { text: "absent".into(), exact: true, include_deleted: false, limit: 10, cursor: None })
        .unwrap();
    assert_eq!(none.total_count, 0);

    let unique = store.create_note("Unique Text", None).unwrap().item;
    let one = store
        .search(SearchQuery {
            text: "unique text".into(),
            exact: true,
            include_deleted: false,
            limit: 10,
            cursor: None,
        })
        .unwrap();
    assert_eq!(one.total_count, 1);
    assert_eq!(one.items[0].item.id, unique.item.id);

    // Duplicates across open and done are both returned, never silently
    // narrowed to the open one.
    let open_dup = store.create_note("dup text", None).unwrap().item;
    let done_dup = store.create_note("dup text", None).unwrap().item;
    store.complete(&done_dup.item.id.to_string(), &Default::default()).unwrap();
    let many = store
        .search(SearchQuery { text: "dup text".into(), exact: true, include_deleted: false, limit: 10, cursor: None })
        .unwrap();
    assert_eq!(many.total_count, 2);
    let ids: HashSet<_> = many.items.iter().map(|v| v.item.id).collect();
    assert!(ids.contains(&open_dup.item.id) && ids.contains(&done_dup.item.id));
}

#[test]
fn search_excludes_deleted_unless_asked_for() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let item = store.create_note("will be deleted", None).unwrap().item;
    store.delete(&item.item.id.to_string(), &Default::default()).unwrap();

    let excluded = store
        .search(SearchQuery {
            text: "will be deleted".into(),
            exact: true,
            include_deleted: false,
            limit: 10,
            cursor: None,
        })
        .unwrap();
    assert_eq!(excluded.total_count, 0);

    let included = store
        .search(SearchQuery {
            text: "will be deleted".into(),
            exact: true,
            include_deleted: true,
            limit: 10,
            cursor: None,
        })
        .unwrap();
    assert_eq!(included.total_count, 1);
}

#[test]
fn search_substring_is_literal_and_normalized() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    store.create_note("Review Deployment Plan", None).unwrap();

    let substring = store
        .search(SearchQuery { text: "eploy".into(), exact: false, include_deleted: false, limit: 10, cursor: None })
        .unwrap();
    assert_eq!(substring.total_count, 1, "case-folded literal substring match");

    let no_wildcards = store
        .search(SearchQuery { text: "%deploy%".into(), exact: false, include_deleted: false, limit: 10, cursor: None })
        .unwrap();
    assert_eq!(no_wildcards.total_count, 0, "% is literal text, not a LIKE wildcard");
}

#[test]
fn exact_search_matches_outer_whitespace_case_and_nfc_but_not_internal_differences() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    // Leading/trailing whitespace, precomposed accent, single internal space.
    store.create_note("  Caf\u{e9} Meeting  ", None).unwrap();

    let matches = store
        .search(SearchQuery {
            text: "cafe\u{301} meeting".into(), // decomposed accent + different case
            exact: true,
            include_deleted: false,
            limit: 10,
            cursor: None,
        })
        .unwrap();
    assert_eq!(matches.total_count, 1, "case, NFC, and outer whitespace are normalized away");

    let different_internal_spacing = store
        .search(SearchQuery {
            text: "café  meeting".into(),
            exact: true,
            include_deleted: false,
            limit: 10,
            cursor: None,
        })
        .unwrap();
    assert_eq!(different_internal_spacing.total_count, 0, "internal whitespace is preserved, not normalized");
}

#[test]
fn empty_search_text_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    let store = support::open(temp.path());
    let error = store
        .search(SearchQuery { text: "   ".into(), exact: false, include_deleted: false, limit: 10, cursor: None })
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::TextEmpty);
}

#[test]
fn due_filter_lists_open_items_with_a_passed_deadline_earliest_first() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(10_000));
    let mut store = open_with_clock(temp.path(), clock.clone());

    let not_due = store.create_note("not due yet", None).unwrap().item;
    support::insert_active_reminder(temp.path(), not_due.item.id, 999_999, clock.now_ms());

    let due_later = store.create_note("due later", None).unwrap().item;
    support::insert_active_reminder(temp.path(), due_later.item.id, 5_000, clock.now_ms());

    let due_first = store.create_note("due first", None).unwrap().item;
    support::insert_active_reminder(temp.path(), due_first.item.id, 1_000, clock.now_ms());

    let page = store.list(ListQuery { filter: ListFilter::Due, limit: 10, cursor: None }).unwrap();
    let ids: Vec<Uuid> = page.items.iter().map(|v| v.item.id).collect();
    assert_eq!(ids, vec![due_first.item.id, due_later.item.id], "earliest deadline first, not-yet-due excluded");
    assert_eq!(page.total_count, 2);
}
