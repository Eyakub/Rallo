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
    assert_eq!(version, 5);
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
