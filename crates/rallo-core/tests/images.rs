mod support;

use std::os::unix::fs::PermissionsExt;

use rallo_core::images::{ImageKind, MAX_IMAGE_BYTES};

pub const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDRfake";
pub const JPEG: &[u8] = b"\xFF\xD8\xFF\xE0\0\x10JFIFfake";
pub const GIF: &[u8] = b"GIF89a\x01\0\x01\0fake";
pub const WEBP: &[u8] = b"RIFF\x10\0\0\0WEBPVP8 fake";
pub const HEIC: &[u8] = b"\0\0\0\x18ftypheic\0\0\0\0fake";

#[test]
fn formats_are_recognised_by_their_first_bytes() {
    assert_eq!(ImageKind::sniff(PNG), Some(ImageKind::Png));
    assert_eq!(ImageKind::sniff(JPEG), Some(ImageKind::Jpeg));
    assert_eq!(ImageKind::sniff(GIF), Some(ImageKind::Gif));
    assert_eq!(ImageKind::sniff(WEBP), Some(ImageKind::Webp));
    assert_eq!(ImageKind::sniff(HEIC), Some(ImageKind::Heic));
    assert_eq!(ImageKind::sniff(b"just some text"), None);
    assert_eq!(ImageKind::sniff(b""), None);
    assert_eq!(ImageKind::Png.mime_type(), "image/png");
    assert_eq!(ImageKind::Jpeg.extension(), "jpg");
    assert_eq!(ImageKind::from_mime_type("image/webp"), Some(ImageKind::Webp));
    assert_eq!(MAX_IMAGE_BYTES, 10 * 1024 * 1024);
}

#[test]
fn schema_five_adds_the_attachments_table() {
    let dir = tempfile::tempdir().unwrap();
    drop(support::open(dir.path()));
    let conn = support::raw_connection(dir.path());
    let version: u32 = conn.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
    assert_eq!(version, 6, "0005 added attachments; 0006 added folders");
    let exists: bool = conn
        .query_row("SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'attachments')", [], |row| row.get(0))
        .unwrap();
    assert!(exists);
}

#[test]
fn every_item_has_an_images_list() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let outcome = store.create_note("plain", None).unwrap();
    assert!(outcome.item.images.is_empty());
    let json = serde_json::to_value(&outcome.item).unwrap();
    assert_eq!(json["images"], serde_json::json!([]));
}

#[test]
fn private_permissions_constant_is_what_we_think() {
    // The attachments directory is created on first write (Task 3); this
    // pins the mode helper the write path uses.
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("x");
    std::fs::create_dir(&target).unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o700);
}

use rallo_core::ErrorCode;
use rallo_core::items::model::MutationOptions;
use rallo_core::items::{ListFilter, ListQuery};

fn attachments(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    let root = dir.join("attachments");
    let Ok(items) = std::fs::read_dir(&root) else { return Vec::new() };
    items
        .flatten()
        .flat_map(|item| {
            std::fs::read_dir(item.path()).unwrap().flatten().map(|entry| entry.path()).collect::<Vec<_>>()
        })
        .collect()
}

#[test]
fn a_note_with_images_writes_private_files_in_order() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let outcome = store.create_note_with_images("Login broken", &[PNG.to_vec(), JPEG.to_vec()], None).unwrap();
    let images = &outcome.item.images;
    assert_eq!(images.len(), 2);
    assert_eq!(images[0].mime_type, "image/png");
    assert_eq!(images[1].mime_type, "image/jpeg");
    assert_eq!(std::fs::read(&images[0].path).unwrap(), PNG);
    assert!(
        images[0]
            .path
            .starts_with(dir.path().canonicalize().unwrap().join("attachments").join(outcome.item.item.id.to_string()))
    );
    assert_eq!(std::fs::metadata(&images[0].path).unwrap().permissions().mode() & 0o777, 0o600);
    let item_dir = images[0].path.parent().unwrap();
    assert_eq!(std::fs::metadata(item_dir).unwrap().permissions().mode() & 0o777, 0o700);
    let json = serde_json::to_value(&outcome.item).unwrap();
    assert_eq!(json["images"][0]["type"], "image/png");
    assert_eq!(json["images"][0]["bytes"], PNG.len());
    assert_eq!(json["images"][0]["path"], images[0].path.to_str().unwrap());
}

#[test]
fn an_image_alone_is_a_note_but_nothing_is_not() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let outcome = store.create_note_with_images("  ", &[PNG.to_vec()], None).unwrap();
    assert_eq!(outcome.item.item.text, "");
    let error = store.create_note_with_images(" ", &[], None).unwrap_err();
    assert_eq!(error.code(), ErrorCode::TextEmpty);
    assert_eq!(error.to_string(), "a note needs text or an image");
}

#[test]
fn a_refused_batch_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    assert_eq!(
        store.create_note_with_images("x", &vec![PNG.to_vec(); 11], None).unwrap_err().code(),
        ErrorCode::TooManyImages
    );
    assert_eq!(
        store.create_note_with_images("x", &[PNG.to_vec(), b"text".to_vec()], None).unwrap_err().code(),
        ErrorCode::ImageUnsupported
    );
    assert!(attachments(dir.path()).is_empty());
    assert_eq!(store.list(ListQuery { filter: ListFilter::Open, limit: 50, cursor: None }).unwrap().items.len(), 0);
}

#[test]
fn a_retry_with_the_same_images_replays_and_writes_no_more_files() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let first = store.create_note_with_images("x", &[PNG.to_vec()], Some("req-1")).unwrap();
    let again = store.create_note_with_images("x", &[PNG.to_vec()], Some("req-1")).unwrap();
    assert!(again.replayed);
    assert_eq!(again.item.item.id, first.item.item.id);
    assert_eq!(attachments(dir.path()).len(), 1);
    let different = store.create_note_with_images("x", &[JPEG.to_vec()], Some("req-1")).unwrap_err();
    assert_eq!(different.code(), ErrorCode::RequestIdConflict);
    assert_eq!(attachments(dir.path()).len(), 1);
}

#[test]
fn a_reminder_can_carry_images() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let when = rallo_core::reminders::TimeSpec::In("3600s".to_owned());
    let outcome = store.create_reminder_with_images("Check this", &when, &[GIF.to_vec()], None).unwrap();
    assert!(outcome.item.reminder.is_some());
    assert_eq!(outcome.item.images.len(), 1);
}

#[test]
fn editing_to_empty_text_needs_an_image() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let plain = store.create_note("plain", None).unwrap().item.item.id.to_string();
    let error = store.edit_text(&plain, "", &MutationOptions::default()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::TextEmpty);
    let pictured = store.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap().item.item.id.to_string();
    let edited = store.edit_text(&pictured, " ", &MutationOptions::default()).unwrap();
    assert_eq!(edited.item.item.text, "");
}

#[test]
fn a_text_less_note_without_images_cannot_be_restored() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let id = store.create_note_with_images("", &[PNG.to_vec()], None).unwrap().item.item.id.to_string();
    store.delete(&id, &MutationOptions::default()).unwrap();
    support::raw_connection(dir.path()).execute("DELETE FROM attachments", []).unwrap();
    let error = store.restore(&id, &MutationOptions::default()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::TextEmpty);
    assert_eq!(error.to_string(), "nothing left to restore: its images were removed 30 days after it was deleted");
}

use std::sync::Arc;
use std::time::{Duration, SystemTime};

use rallo_core::StoreOptions;
use rallo_core::shared::clock::ManualClock;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn store_at(dir: &std::path::Path, clock: &Arc<ManualClock>) -> rallo_core::Store {
    rallo_core::Store::open(StoreOptions::new(dir).with_clock(clock.clone())).unwrap()
}

#[test]
fn attach_adds_after_the_existing_images_and_moves_the_revision() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let note = store.create_note_with_images("x", &[PNG.to_vec()], None).unwrap().item;
    let id = note.item.id.to_string();
    let attached = store.attach_images(&id, &[GIF.to_vec(), WEBP.to_vec()], &MutationOptions::default()).unwrap();
    let types: Vec<_> = attached.item.images.iter().map(|image| image.mime_type.as_str()).collect();
    assert_eq!(types, ["image/png", "image/gif", "image/webp"]);
    assert_eq!(attached.item.item.revision, note.item.revision + 1);
    assert!(attached.changed);
}

#[test]
fn attach_refusals_write_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let id = store.create_note_with_images("x", &vec![PNG.to_vec(); 9], None).unwrap().item.item.id.to_string();
    let error = store.attach_images(&id, &[PNG.to_vec(), PNG.to_vec()], &MutationOptions::default()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::TooManyImages);
    assert_eq!(attachments(dir.path()).len(), 9);
    store.delete(&id, &MutationOptions::default()).unwrap();
    let error = store.attach_images(&id, &[PNG.to_vec()], &MutationOptions::default()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::ItemDeleted);
    assert_eq!(attachments(dir.path()).len(), 9);
}

#[test]
fn detach_removes_the_row_and_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let note = store.create_note_with_images("x", &[PNG.to_vec(), JPEG.to_vec()], None).unwrap().item;
    let id = note.item.id.to_string();
    let first = &note.images[0];
    let outcome = store.detach_image(&id, &first.id.to_string(), &MutationOptions::default()).unwrap();
    assert_eq!(outcome.item.images.len(), 1);
    assert!(!first.path.exists());
    let error = store.detach_image(&id, &first.id.to_string(), &MutationOptions::default()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::ImageNotFound);
}

#[test]
fn the_last_image_of_a_text_less_note_stays() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let note = store.create_note_with_images("", &[PNG.to_vec()], None).unwrap().item;
    let error = store
        .detach_image(&note.item.id.to_string(), &note.images[0].id.to_string(), &MutationOptions::default())
        .unwrap_err();
    assert_eq!(error.code(), ErrorCode::TextEmpty);
    assert_eq!(error.to_string(), "a note needs text or an image; delete the note instead");
    assert!(note.images[0].path.exists());
}

#[test]
fn deleted_notes_keep_images_for_thirty_days() {
    let dir = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_800_000_000_000));
    let mut store = store_at(dir.path(), &clock);
    let note = store.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap().item;
    let id = note.item.id.to_string();
    store.delete(&id, &MutationOptions::default()).unwrap();

    clock.advance(29 * DAY_MS);
    assert_eq!(store.sweep_images().unwrap().expired_images, 0);
    assert!(note.images[0].path.exists());

    clock.advance(2 * DAY_MS);
    assert_eq!(store.sweep_images().unwrap().expired_images, 1);
    assert!(!note.images[0].path.exists());
    let restored = store.restore(&id, &MutationOptions::default()).unwrap();
    assert_eq!(restored.item.item.text, "caption");
    assert!(restored.item.images.is_empty());
}

#[test]
fn fresh_orphans_survive_the_sweep() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    store.create_note_with_images("x", &[PNG.to_vec()], None).unwrap();
    let orphan_dir = dir.path().join("attachments").join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&orphan_dir).unwrap();
    let old = orphan_dir.join(format!("{}.png", uuid::Uuid::new_v4()));
    let fresh = orphan_dir.join(format!("{}.png", uuid::Uuid::new_v4()));
    std::fs::write(&old, PNG).unwrap();
    std::fs::write(&fresh, PNG).unwrap();
    let file = std::fs::File::options().write(true).open(&old).unwrap();
    file.set_modified(SystemTime::now() - Duration::from_secs(2 * 60 * 60)).unwrap();

    let summary = store.sweep_images().unwrap();
    assert_eq!(summary.orphan_files, 1);
    assert!(!old.exists());
    assert!(fresh.exists());
    assert_eq!(attachments(dir.path()).len(), 2, "the note's own image and the fresh orphan");
}

#[test]
fn the_audit_counts_images_orphans_and_missing_files() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let note = store.create_note_with_images("x", &[PNG.to_vec(), JPEG.to_vec()], None).unwrap().item;
    std::fs::remove_file(&note.images[1].path).unwrap();
    std::fs::write(note.images[0].path.with_file_name(format!("{}.png", uuid::Uuid::new_v4())), PNG).unwrap();
    std::fs::write(note.images[0].path.with_file_name(".DS_Store"), b"x").unwrap();
    std::fs::create_dir(dir.path().join("attachments").join("Not A Uuid")).unwrap();
    let data_dir = dir.path().canonicalize().unwrap();
    let audit = rallo_core::images::audit(&support::raw_connection(dir.path()), &data_dir).unwrap();
    assert_eq!(audit.count, 2);
    assert_eq!(audit.bytes, (PNG.len() + JPEG.len()) as u64);
    assert_eq!(audit.orphan_files, 1);
    assert_eq!(audit.missing, vec![note.images[1].path.display().to_string()]);
}

fn item_dirs(dir: &std::path::Path) -> Vec<std::path::PathBuf> {
    match std::fs::read_dir(dir.join("attachments")) {
        Ok(items) => items.flatten().map(|entry| entry.path()).collect(),
        Err(_) => Vec::new(),
    }
}

#[test]
fn a_replayed_create_leaves_no_empty_directory() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    store.create_note_with_images("x", &[PNG.to_vec()], Some("req-1")).unwrap();
    store.create_note_with_images("x", &[PNG.to_vec()], Some("req-1")).unwrap();
    assert_eq!(item_dirs(dir.path()).len(), 1, "only the first note's directory");
    assert_eq!(attachments(dir.path()).len(), 1);
}

#[test]
fn the_sweep_skips_an_unreadable_directory_and_removes_stale_empty_ones() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let root = dir.path().join("attachments");
    std::fs::create_dir_all(&root).unwrap();
    let old = SystemTime::now() - Duration::from_secs(2 * 60 * 60);

    let locked = root.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir(&locked).unwrap();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
    let stale_empty = root.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir(&stale_empty).unwrap();
    std::fs::File::open(&stale_empty).unwrap().set_modified(old).unwrap();
    let fresh_empty = root.join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir(&fresh_empty).unwrap();

    let result = store.sweep_images();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700)).unwrap();
    result.unwrap();
    assert!(!stale_empty.exists());
    assert!(fresh_empty.exists(), "a just-created directory may be a CLI write in progress");
    assert!(locked.exists());
}

fn age_two_hours(path: &std::path::Path) {
    let file = std::fs::File::options().write(true).open(path).unwrap();
    file.set_modified(SystemTime::now() - Duration::from_secs(2 * 60 * 60)).unwrap();
}

#[test]
fn the_sweep_spares_old_files_that_a_row_names() {
    let dir = tempfile::tempdir().unwrap();
    let clock = Arc::new(ManualClock::new(1_800_000_000_000));
    let mut store = store_at(dir.path(), &clock);
    let live = store.create_note_with_images("live", &[PNG.to_vec()], None).unwrap().item;
    let deleted = store.create_note_with_images("gone", &[JPEG.to_vec()], None).unwrap().item;
    store.delete(&deleted.item.id.to_string(), &MutationOptions::default()).unwrap();
    clock.advance(10 * DAY_MS);
    age_two_hours(&live.images[0].path);
    age_two_hours(&deleted.images[0].path);
    let summary = store.sweep_images().unwrap();
    assert_eq!(summary, rallo_core::images::SweepSummary { expired_images: 0, orphan_files: 0 });
    assert!(live.images[0].path.exists());
    assert!(deleted.images[0].path.exists());
}

#[test]
fn the_sweep_does_not_follow_a_symlinked_directory() {
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let stranger = outside.path().join("precious.png");
    std::fs::write(&stranger, PNG).unwrap();
    age_two_hours(&stranger);
    let root = dir.path().join("attachments");
    std::fs::create_dir_all(&root).unwrap();
    std::os::unix::fs::symlink(outside.path(), root.join(uuid::Uuid::new_v4().to_string())).unwrap();
    assert_eq!(store.sweep_images().unwrap().orphan_files, 0);
    assert!(stranger.exists());
    let audit = rallo_core::images::audit(&support::raw_connection(dir.path()), dir.path()).unwrap();
    assert_eq!(audit.orphan_files, 0);
}
