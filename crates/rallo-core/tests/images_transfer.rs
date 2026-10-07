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
