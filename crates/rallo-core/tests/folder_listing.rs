//! 0019 §6-§7: `--folder`, `--tag` and `--done` on list and search, the
//! counts that go with them, and the `tags` and `folder` fields of item JSON.

mod support;

use std::collections::HashSet;
use std::sync::Arc;

use rallo_core::ErrorCode;
use rallo_core::Store;
use rallo_core::StoreOptions;
use rallo_core::folders::FolderSelector;
use rallo_core::items::{ItemScope, ListFilter, ListQuery, MutationOptions, SearchQuery, TagCount};
use rallo_core::shared::clock::{Clock, ManualClock};
use serde_json::json;
use uuid::Uuid;

fn open_with_clock(dir: &std::path::Path, clock: Arc<ManualClock>) -> Store {
    Store::open(StoreOptions::new(dir).with_clock(clock)).expect("store opens")
}

fn in_folder(name: &str) -> ItemScope {
    ItemScope { folder: Some(FolderSelector::named(name)), tag: None }
}

fn with_tag(tag: &str) -> ItemScope {
    ItemScope { folder: None, tag: Some(tag.to_owned()) }
}

fn query(filter: ListFilter, limit: u32) -> ListQuery {
    ListQuery { filter, limit, cursor: None }
}

fn texts(store: &Store, filter: ListFilter, scope: &ItemScope) -> Vec<String> {
    store.list_scoped(query(filter, 200), scope).unwrap().items.into_iter().map(|view| view.item.text).collect()
}

fn opts() -> MutationOptions {
    MutationOptions::default()
}

/// Work: "w1 #bug", "w2", "w3 #Bug #ui"; Notes: "n1 #bug", "n2"; the clock
/// moves a second between notes so "newest first" is unambiguous.
fn seeded(dir: &std::path::Path, clock: &Arc<ManualClock>) -> Store {
    let mut store = open_with_clock(dir, clock.clone());
    store.create_folder("Work", None).unwrap();
    for (text, folder) in
        [("w1 #bug", "Work"), ("n1 #bug", "Notes"), ("w2", "Work"), ("n2", "Notes"), ("w3 #Bug #ui", "Work")]
    {
        clock.advance(1_000);
        store.create_note_in(text, &[], &FolderSelector::named(folder), None).unwrap();
    }
    store
}

#[test]
fn list_folder_filters_with_a_total_count_and_notes_means_no_folder() {
    let temp = tempfile::tempdir().unwrap();
    let store = seeded(temp.path(), &Arc::new(ManualClock::new(1_000)));

    assert_eq!(texts(&store, ListFilter::Open, &in_folder("work")), ["w3 #Bug #ui", "w2", "w1 #bug"]);
    assert_eq!(texts(&store, ListFilter::Open, &in_folder("Notes")), ["n2", "n1 #bug"]);
    assert_eq!(texts(&store, ListFilter::Open, &ItemScope::default()).len(), 5, "no scope is every folder");
    let page = store.list_scoped(query(ListFilter::Open, 1), &in_folder("Work")).unwrap();
    assert_eq!((page.items.len(), page.total_count), (1, 3), "total_count counts the folder, not the page");

    let error = store.list_scoped(query(ListFilter::Open, 10), &in_folder("Wrok")).unwrap_err();
    assert_eq!(error.code(), ErrorCode::FolderNotFound);
}

#[test]
fn cursors_walk_a_folder_and_a_tag_exactly_once() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    store.create_folder("Work", None).unwrap();
    let mut expected = HashSet::new();
    for n in 0..9 {
        clock.advance(10);
        let folder = if n % 3 == 0 { "Notes" } else { "Work" };
        let item =
            store.create_note_in(&format!("note {n} #t"), &[], &FolderSelector::named(folder), None).unwrap().item;
        if folder == "Work" {
            expected.insert(item.item.id);
        }
    }

    let scope = ItemScope { folder: Some(FolderSelector::named("Work")), tag: Some("#t".into()) };
    let mut seen = HashSet::new();
    let mut cursor = None;
    loop {
        let page = store.list_scoped(ListQuery { filter: ListFilter::Open, limit: 2, cursor }, &scope).unwrap();
        assert_eq!(page.total_count, 6);
        for view in &page.items {
            assert!(seen.insert(view.item.id), "{} came twice", view.item.id);
        }
        cursor = page.next_cursor;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(seen, expected);
}

#[test]
fn tag_filter_matches_whole_tags_case_insensitively_with_or_without_the_hash() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = seeded(temp.path(), &clock);
    for text in ["fix #123 and C# and a#bug", "#bugfix is another tag", "see https://x.y/#bug", "কাজ #কাজ"]
    {
        clock.advance(1_000);
        store.create_note(text, None).unwrap();
    }

    for tag in ["bug", "#bug", "#BUG", "Bug"] {
        assert_eq!(texts(&store, ListFilter::Open, &with_tag(tag)), ["w3 #Bug #ui", "n1 #bug", "w1 #bug"], "{tag}");
    }
    assert_eq!(texts(&store, ListFilter::Open, &with_tag("ui")), ["w3 #Bug #ui"]);
    assert_eq!(texts(&store, ListFilter::Open, &with_tag("কাজ")), ["কাজ #কাজ"]);
    assert_eq!(texts(&store, ListFilter::Open, &with_tag("bugfix")), ["#bugfix is another tag"]);
    let page = store.list_scoped(query(ListFilter::Open, 1), &with_tag("bug")).unwrap();
    assert_eq!(page.total_count, 3);

    for bad in ["", "#", "123", "two words", "bug-"] {
        let error = store.list_scoped(query(ListFilter::Open, 10), &with_tag(bad)).unwrap_err();
        assert_eq!(error.code(), ErrorCode::InvalidInput, "{bad:?}");
    }
}

#[test]
fn folder_and_tag_combine_with_each_other_and_with_every_filter() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = seeded(temp.path(), &clock);
    let both = ItemScope { folder: Some(FolderSelector::named("Work")), tag: Some("bug".into()) };
    assert_eq!(texts(&store, ListFilter::Open, &both), ["w3 #Bug #ui", "w1 #bug"]);

    // Done and deleted notes join the right filters only.
    let w1 =
        store.list(query(ListFilter::Open, 200)).unwrap().items.into_iter().find(|v| v.item.text == "w1 #bug").unwrap();
    let w3 = store
        .list(query(ListFilter::Open, 200))
        .unwrap()
        .items
        .into_iter()
        .find(|v| v.item.text.starts_with("w3"))
        .unwrap();
    clock.advance(1_000);
    store.complete(&w1.item.id.to_string(), &opts()).unwrap();
    store.delete(&w3.item.id.to_string(), &opts()).unwrap();
    assert_eq!(texts(&store, ListFilter::Open, &both), Vec::<String>::new());
    assert_eq!(texts(&store, ListFilter::Done, &both), ["w1 #bug"]);
    assert_eq!(texts(&store, ListFilter::All, &both), ["w1 #bug"]);
    assert_eq!(texts(&store, ListFilter::Deleted, &both), ["w3 #Bug #ui"]);
    assert_eq!(texts(&store, ListFilter::Deleted, &in_folder("Notes")), Vec::<String>::new());

    // Due: a reminder past its deadline, in and out of the folder.
    let w2 = store.list(query(ListFilter::Open, 200)).unwrap().items.into_iter().find(|v| v.item.text == "w2").unwrap();
    let n2 = store.list(query(ListFilter::Open, 200)).unwrap().items.into_iter().find(|v| v.item.text == "n2").unwrap();
    // Earliest deadline first: w2 is due before n2.
    for (id, deadline) in [(w2.item.id, 1_500), (n2.item.id, 1_600)] {
        support::insert_active_reminder(temp.path(), id, deadline, clock.now_ms());
    }
    assert_eq!(texts(&store, ListFilter::Due, &ItemScope::default()), ["w2", "n2"]);
    assert_eq!(texts(&store, ListFilter::Due, &in_folder("Work")), ["w2"]);
    assert_eq!(texts(&store, ListFilter::Due, &in_folder("Notes")), ["n2"]);
    assert_eq!(store.list_scoped(query(ListFilter::Due, 1), &in_folder("Work")).unwrap().total_count, 1);
}

#[test]
fn done_lists_done_nondeleted_notes_newest_completion_first_with_stable_cursors() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = open_with_clock(temp.path(), clock.clone());
    let ids: Vec<Uuid> = (0..5)
        .map(|n| {
            clock.advance(10);
            store.create_note(&format!("note {n}"), None).unwrap().item.item.id
        })
        .collect();
    // Completed in the order 2, 0, 4, then 1 and 3 in the same millisecond.
    for index in [2, 0, 4] {
        clock.advance(100);
        store.complete(&ids[index].to_string(), &opts()).unwrap();
    }
    clock.advance(100);
    store.complete(&ids[1].to_string(), &opts()).unwrap();
    store.complete(&ids[3].to_string(), &opts()).unwrap();
    store.delete(&ids[2].to_string(), &opts()).unwrap(); // done but deleted: not listed
    store.create_note("still open", None).unwrap();

    let mut tied = [ids[1], ids[3]];
    tied.sort();
    tied.reverse(); // same completed_at_ms: id descending
    let expected: Vec<Uuid> = tied.into_iter().chain([ids[4], ids[0]]).collect();
    let all = store.list(query(ListFilter::Done, 200)).unwrap();
    assert_eq!(all.items.iter().map(|view| view.item.id).collect::<Vec<_>>(), expected);
    assert_eq!(all.total_count, 4);

    let mut walked = Vec::new();
    let mut cursor = None;
    loop {
        let page = store.list(ListQuery { filter: ListFilter::Done, limit: 1, cursor }).unwrap();
        walked.extend(page.items.iter().map(|view| view.item.id));
        cursor = page.next_cursor;
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(walked, expected, "one note per page, none repeated or skipped");
}

#[test]
fn search_takes_a_folder_and_a_tag() {
    let temp = tempfile::tempdir().unwrap();
    let store = seeded(temp.path(), &Arc::new(ManualClock::new(1_000)));
    let search = |text: &str, scope: &ItemScope| {
        let query = SearchQuery { text: text.into(), exact: false, include_deleted: false, limit: 50, cursor: None };
        let page = store.search_scoped(query, scope).unwrap();
        (page.items.into_iter().map(|view| view.item.text).collect::<Vec<_>>(), page.total_count)
    };
    assert_eq!(search("bug", &ItemScope::default()).1, 3);
    assert_eq!(search("bug", &in_folder("Work")), (vec!["w3 #Bug #ui".to_owned(), "w1 #bug".to_owned()], 2));
    assert_eq!(search("bug", &in_folder("Notes")), (vec!["n1 #bug".to_owned()], 1));
    assert_eq!(search("w", &with_tag("ui")).1, 1);
    let unknown = ItemScope { folder: Some(FolderSelector::named("Nope")), tag: None };
    let query = SearchQuery { text: "w".into(), exact: false, include_deleted: false, limit: 50, cursor: None };
    assert_eq!(store.search_scoped(query, &unknown).unwrap_err().code(), ErrorCode::FolderNotFound);
}

#[test]
fn tag_counts_cover_open_nondeleted_notes_most_used_first() {
    let temp = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_000));
    let mut store = seeded(temp.path(), &clock);
    let count = |name: &str, open_count: u64| TagCount { name: name.to_owned(), open_count };
    // w1, n1, w3 carry #bug (w3 twice, counted once); w3 also has #ui.
    assert_eq!(store.tag_counts().unwrap(), [count("bug", 3), count("ui", 1)]);

    let done = store.create_note("only in a done note #finished", None).unwrap().item.item;
    let gone = store.create_note("only in a deleted note #removed", None).unwrap().item.item;
    store.complete(&done.id.to_string(), &opts()).unwrap();
    store.delete(&gone.id.to_string(), &opts()).unwrap();
    store.create_note("#apple and #Zed", None).unwrap();
    store.create_note("#zed", None).unwrap();
    assert_eq!(
        store.tag_counts().unwrap(),
        [count("bug", 3), count("zed", 2), count("apple", 1), count("ui", 1)],
        "most used first, then alphabetical; done and deleted tags are left out"
    );
}

#[test]
fn item_json_carries_the_folder_and_the_tags_in_first_appearance_order() {
    let temp = tempfile::tempdir().unwrap();
    let mut store = support::open(temp.path());
    let work = store.create_folder("Work", None).unwrap().folder;
    let view =
        store.create_note_in("#Zeta then #alpha, #ZETA again", &[], &FolderSelector::named("Work"), None).unwrap().item;
    let json = serde_json::to_value(&view).unwrap();
    assert_eq!(json["tags"], json!(["zeta", "alpha"]));
    assert_eq!(json["folder"], json!({ "id": work.id, "name": "Work" }));

    let plain = serde_json::to_value(store.create_note("no tags here", None).unwrap().item).unwrap();
    assert_eq!(plain["tags"], json!([]));
    assert!(plain["folder"].is_null());
    assert!(plain.get("folder_id").is_none(), "the id is the folder's `id`, not a separate key");
}
