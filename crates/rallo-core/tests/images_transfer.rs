mod support;

use rallo_core::ErrorCode;
use rallo_core::transfer::export::ExportFormat;

const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDRfake";
const GIF: &[u8] = b"GIF89a\x01\0\x01\0fake";

#[test]
fn a_backup_copies_the_images() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let note = store.create_note_with_images("x", &[PNG.to_vec()], None).unwrap().item;
    let destination = dir.path().join("backups").join("manual-1.sqlite3");
    let summary = store.backup_to_file(&destination, false).unwrap();
    assert_eq!(summary.images, 1);
    let copy = dir
        .path()
        .join("backups")
        .join("manual-1.sqlite3.attachments")
        .join(note.item.id.to_string())
        .join(note.images[0].path.file_name().unwrap());
    assert_eq!(std::fs::read(copy).unwrap(), PNG);
}

#[test]
fn a_database_only_backup_writes_no_attachments_folder() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    store.create_note_with_images("x", &[PNG.to_vec()], None).unwrap();
    let destination = dir.path().join("backups").join("pre-update.sqlite3");
    let summary = store.backup_database_to_file(&destination, false).unwrap();
    assert_eq!(summary.images, 0);
    assert!(destination.exists());
    assert!(!dir.path().join("backups").join("pre-update.sqlite3.attachments").exists());
}

#[test]
fn a_directory_export_round_trips_images() {
    let source_dir = tempfile::tempdir().unwrap();
    let mut source = support::open(source_dir.path());
    let note = source.create_note_with_images("caption", &[PNG.to_vec(), GIF.to_vec()], None).unwrap().item;
    let image_only = source.create_note_with_images("", &[PNG.to_vec()], None).unwrap().item;

    let export_dir = tempfile::tempdir().unwrap();
    let summary = source.export_to_dir(export_dir.path()).unwrap();
    assert_eq!(summary.items, 2);
    let document: serde_json::Value =
        serde_json::from_slice(&std::fs::read(export_dir.path().join("rallo-export.json")).unwrap()).unwrap();
    assert_eq!(document["version"], 2);
    let file = document["items"][0]["images"][0]["file"].as_str().unwrap().to_owned();
    assert!(file.starts_with("images/"));
    assert_eq!(std::fs::read(export_dir.path().join(&file)).unwrap(), PNG);

    let target_dir = tempfile::tempdir().unwrap();
    let mut target = support::open(target_dir.path());
    let preview = target.preview_import_dir(export_dir.path()).unwrap();
    assert_eq!(preview.new, 2);
    let report = target.apply_import_dir(export_dir.path()).unwrap();
    assert!(report.applied);
    let imported = target.get_item(&note.item.id.to_string()).unwrap();
    assert_eq!(imported.images.len(), 2);
    assert_eq!(imported.images[0].id, note.images[0].id);
    assert_eq!(std::fs::read(&imported.images[1].path).unwrap(), GIF);
    assert_eq!(target.get_item(&image_only.item.id.to_string()).unwrap().item.text, "");
}

#[test]
fn plain_json_and_csv_leave_image_only_notes_out_and_say_so() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    store.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap();
    store.create_note_with_images("", &[PNG.to_vec()], None).unwrap();
    let out = dir.path().join("out.json");
    let summary = store.export_to_file(&out, ExportFormat::Json, false).unwrap();
    assert_eq!(summary.items, 1);
    assert!(summary.warnings.iter().any(|warning| warning == "2 images aren't included; use --format zip"));
    assert!(summary.warnings.iter().any(|warning| warning == "1 image-only note was left out"));
    let document: serde_json::Value = serde_json::from_slice(&std::fs::read(&out).unwrap()).unwrap();
    assert_eq!(document["version"], 1);
    assert!(document["items"][0].get("images").is_none());
}

#[test]
fn a_document_with_images_needs_its_archive() {
    let source_dir = tempfile::tempdir().unwrap();
    let mut source = support::open(source_dir.path());
    source.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap();
    let export_dir = tempfile::tempdir().unwrap();
    source.export_to_dir(export_dir.path()).unwrap();
    let bytes = std::fs::read(export_dir.path().join("rallo-export.json")).unwrap();
    let target_dir = tempfile::tempdir().unwrap();
    let error = support::open(target_dir.path()).preview_import(&bytes).unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidImport);
    assert!(error.to_string().contains("import the .zip it came in"));
}

#[test]
fn image_files_are_checked_before_anything_is_written() {
    let source_dir = tempfile::tempdir().unwrap();
    let mut source = support::open(source_dir.path());
    let note = source.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap().item;
    let export_dir = tempfile::tempdir().unwrap();
    source.export_to_dir(export_dir.path()).unwrap();
    let image =
        export_dir.path().join("images").join(note.item.id.to_string()).join(note.images[0].path.file_name().unwrap());

    std::fs::write(&image, b"not an image").unwrap();
    let target_dir = tempfile::tempdir().unwrap();
    let mut target = support::open(target_dir.path());
    assert_eq!(target.apply_import_dir(export_dir.path()).unwrap_err().code(), ErrorCode::InvalidImport);

    std::fs::remove_file(&image).unwrap();
    assert_eq!(target.apply_import_dir(export_dir.path()).unwrap_err().code(), ErrorCode::InvalidImport);
    assert!(target.get_item(&note.item.id.to_string()).is_err(), "nothing was imported");
    assert!(!target_dir.path().join("attachments").exists());
}

#[test]
fn a_backup_does_not_follow_a_symlinked_directory() {
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret.png"), PNG).unwrap();
    let mut store = support::open(dir.path());
    store.create_note_with_images("x", &[PNG.to_vec()], None).unwrap();
    std::os::unix::fs::symlink(outside.path(), dir.path().join("attachments").join("linked")).unwrap();
    let destination = dir.path().join("backups").join("manual-2.sqlite3");
    let summary = store.backup_to_file(&destination, false).unwrap();
    assert_eq!(summary.images, 1);
    assert!(!dir.path().join("backups").join("manual-2.sqlite3.attachments").join("linked").exists());
}

#[test]
fn an_expired_image_only_note_is_skipped_and_the_zip_export_still_imports() {
    use rallo_core::items::model::MutationOptions;
    use rallo_core::shared::clock::ManualClock;
    let dir = tempfile::tempdir().unwrap();
    let clock = std::sync::Arc::new(ManualClock::new(1_800_000_000_000));
    let mut store =
        rallo_core::Store::open(rallo_core::StoreOptions::new(dir.path()).with_clock(clock.clone())).unwrap();
    store.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap();
    let gone = store.create_note_with_images("", &[PNG.to_vec()], None).unwrap().item;
    store.delete(&gone.item.id.to_string(), &MutationOptions::default()).unwrap();
    clock.advance(31 * 24 * 60 * 60 * 1000);
    store.sweep_images().unwrap();

    let export_dir = tempfile::tempdir().unwrap();
    assert_eq!(store.export_to_dir(export_dir.path()).unwrap().items, 1);
    let document = std::fs::read_to_string(export_dir.path().join("rallo-export.json")).unwrap();
    assert!(!document.contains(&gone.item.id.to_string()));
    let target_dir = tempfile::tempdir().unwrap();
    assert!(support::open(target_dir.path()).apply_import_dir(export_dir.path()).unwrap().applied);
}

#[test]
fn a_missing_image_file_is_left_out_with_a_warning() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = support::open(dir.path());
    let note = store.create_note_with_images("keep me", &[PNG.to_vec(), GIF.to_vec()], None).unwrap().item;
    let only = store.create_note_with_images("", &[PNG.to_vec()], None).unwrap().item;
    std::fs::remove_file(&note.images[0].path).unwrap();
    std::fs::remove_file(&only.images[0].path).unwrap();
    let export_dir = tempfile::tempdir().unwrap();
    let summary = store.export_to_dir(export_dir.path()).unwrap();
    assert_eq!(summary.items, 1);
    assert_eq!(summary.warnings, ["2 image files are missing and were left out; run `rallo doctor`"]);
    let document = std::fs::read_to_string(export_dir.path().join("rallo-export.json")).unwrap();
    assert!(document.contains("keep me"));
    assert!(!document.contains(&note.images[0].id.to_string()));
    assert!(document.contains(&note.images[1].id.to_string()));
    assert!(!document.contains(&only.item.id.to_string()));
    let target_dir = tempfile::tempdir().unwrap();
    assert!(support::open(target_dir.path()).apply_import_dir(export_dir.path()).unwrap().applied);
}

fn one_image_export(source_dir: &std::path::Path, export_dir: &std::path::Path) -> (String, String) {
    let mut source = support::open(source_dir);
    let note = source.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap().item;
    source.export_to_dir(export_dir).unwrap();
    (note.item.id.to_string(), note.images[0].id.to_string())
}

#[test]
fn an_image_id_twice_in_a_document_is_refused_and_nothing_is_written() {
    let source_dir = tempfile::tempdir().unwrap();
    let export_dir = tempfile::tempdir().unwrap();
    one_image_export(source_dir.path(), export_dir.path());
    let path = export_dir.path().join("rallo-export.json");
    let mut document: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let image = document["items"][0]["images"][0].clone();
    document["items"][0]["images"].as_array_mut().unwrap().push(image);
    std::fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();

    let target_dir = tempfile::tempdir().unwrap();
    let mut target = support::open(target_dir.path());
    let error = target.apply_import_dir(export_dir.path()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidImport);
    assert!(error.to_string().contains("appears twice"), "{error}");
    assert!(!target_dir.path().join("attachments").exists());
}

#[test]
fn an_image_id_already_in_the_store_is_refused_and_nothing_is_written() {
    let source_dir = tempfile::tempdir().unwrap();
    let export_dir = tempfile::tempdir().unwrap();
    let (item, _) = one_image_export(source_dir.path(), export_dir.path());
    let target_dir = tempfile::tempdir().unwrap();
    let mut target = support::open(target_dir.path());
    target.apply_import_dir(export_dir.path()).unwrap();

    // The same image under a different note id.
    let other = uuid::Uuid::new_v4().to_string();
    let path = export_dir.path().join("rallo-export.json");
    let document = std::fs::read_to_string(&path).unwrap().replace(&item, &other);
    std::fs::write(&path, document).unwrap();
    std::fs::rename(export_dir.path().join("images").join(&item), export_dir.path().join("images").join(&other))
        .unwrap();
    let error = target.apply_import_dir(export_dir.path()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidImport);
    assert!(error.to_string().contains("is already in Rallo"), "{error}");
    assert!(target.get_item(&other).is_err());
}

#[test]
fn a_failure_after_the_first_records_files_were_copied_leaves_none_behind() {
    let source_dir = tempfile::tempdir().unwrap();
    let mut source = support::open(source_dir.path());
    source.create_note_with_images("one", &[PNG.to_vec()], None).unwrap();
    source.create_note_with_images("two", &[GIF.to_vec()], None).unwrap();
    let export_dir = tempfile::tempdir().unwrap();
    source.export_to_dir(export_dir.path()).unwrap();
    let document: serde_json::Value =
        serde_json::from_slice(&std::fs::read(export_dir.path().join("rallo-export.json")).unwrap()).unwrap();
    let first = document["items"][0]["id"].as_str().unwrap().to_owned();
    let second = &document["items"][1];
    let second_file = second["images"][0]["file"].as_str().unwrap().rsplit('/').next().unwrap().to_owned();

    // A directory where the second record's image must land makes its copy fail.
    let target_dir = tempfile::tempdir().unwrap();
    let blocked = target_dir.path().join("attachments").join(second["id"].as_str().unwrap()).join(&second_file);
    std::fs::create_dir_all(&blocked).unwrap();
    let mut target = support::open(target_dir.path());
    assert!(target.apply_import_dir(export_dir.path()).is_err());
    assert!(target.get_item(&first).is_err(), "the first record rolled back");
    assert!(!target_dir.path().join("attachments").join(&first).exists(), "its copied file is gone");
}

#[test]
fn an_archive_document_without_the_format_tag_is_not_read_as_csv() {
    let export_dir = tempfile::tempdir().unwrap();
    std::fs::write(export_dir.path().join("rallo-export.json"), b"{\"items\": []}").unwrap();
    let target_dir = tempfile::tempdir().unwrap();
    let error = support::open(target_dir.path()).preview_import_dir(export_dir.path()).unwrap_err();
    assert_eq!(error.code(), ErrorCode::InvalidImport);
    assert!(error.to_string().contains("rallo-export.json isn't a Rallo export"), "{error}");
}

#[test]
fn the_left_out_warning_ignores_notes_whose_images_expired() {
    use rallo_core::items::model::MutationOptions;
    use rallo_core::shared::clock::ManualClock;
    let dir = tempfile::tempdir().unwrap();
    let clock = std::sync::Arc::new(ManualClock::new(1_800_000_000_000));
    let mut store =
        rallo_core::Store::open(rallo_core::StoreOptions::new(dir.path()).with_clock(clock.clone())).unwrap();
    store.create_note_with_images("caption", &[PNG.to_vec()], None).unwrap();
    let gone = store.create_note_with_images("", &[PNG.to_vec()], None).unwrap().item;
    store.delete(&gone.item.id.to_string(), &MutationOptions::default()).unwrap();
    clock.advance(31 * 24 * 60 * 60 * 1000);
    store.sweep_images().unwrap();
    let warnings = store.export_warnings(ExportFormat::Json).unwrap();
    assert_eq!(warnings, ["1 image isn't included; use --format zip"]);
}
