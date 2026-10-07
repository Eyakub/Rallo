//! Zip archives for `export --format zip` and for importing them (0018),
//! made and opened with macOS's own `ditto`, listed with `zipinfo`. Only
//! Rallo's own layout is accepted: `rallo-export.json` and
//! `images/<uuid>/<uuid>.<ext>`.

use std::fs::{self, DirBuilder};
use std::io::{self, Read};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_ARCHIVE_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum ArchiveError {
    #[error("{0}")]
    Io(#[from] io::Error),
    #[error("not a Rallo archive: {0}")]
    Unreadable(String),
    #[error("not a Rallo archive: it contains \"{0}\"")]
    Unsafe(String),
    #[error("the archive is over 1 GB")]
    TooLarge,
}

pub fn is_zip(path: &Path) -> io::Result<bool> {
    let mut magic = [0u8; 4];
    let read = fs::File::open(path)?.read(&mut magic)?;
    Ok(read == 4 && magic == *b"PK\x03\x04")
}

/// A new private (0700) directory under the system temp directory.
pub fn private_temp_dir(label: &str) -> io::Result<PathBuf> {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_nanos()).unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("rallo-{label}-{}-{nanos}", std::process::id()));
    DirBuilder::new().mode(0o700).create(&dir)?;
    Ok(dir)
}

/// Zips `dir`'s contents (not `dir` itself) into `out`.
pub fn zip(dir: &Path, out: &Path) -> Result<(), ArchiveError> {
    let status = Command::new("/usr/bin/ditto")
        .args(["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"])
        .arg(dir)
        .arg(out)
        .status()?;
    if !status.success() {
        return Err(io::Error::other("ditto could not write the archive").into());
    }
    Ok(())
}

/// Writes an archive: `fill` puts the export into a fresh private
/// directory, which is zipped to `<out>.partial` (0600) and renamed to
/// `out`. The directory is always removed. Used by `rallo export`,
/// `rallo uninstall --purge` and the app.
pub fn write_zip<T, E: From<ArchiveError>>(out: &Path, fill: impl FnOnce(&Path) -> Result<T, E>) -> Result<T, E> {
    let staging = private_temp_dir("export").map_err(ArchiveError::from)?;
    let result = fill(&staging).and_then(|value| {
        let mut partial = out.as_os_str().to_owned();
        partial.push(".partial");
        let partial = PathBuf::from(partial);
        let _ = fs::remove_file(&partial);
        zip(&staging, &partial)?;
        fs::set_permissions(&partial, fs::Permissions::from_mode(0o600)).map_err(ArchiveError::from)?;
        fs::rename(&partial, out).map_err(ArchiveError::from)?;
        Ok(value)
    });
    let _ = fs::remove_dir_all(&staging);
    result
}

/// Opens an archive: unzips `archive` (with every check in `unzip`) into a
/// fresh private directory, runs `read` on it, and always removes it.
pub fn read_zip<T, E: From<ArchiveError>>(archive: &Path, read: impl FnOnce(&Path) -> Result<T, E>) -> Result<T, E> {
    let staging = private_temp_dir("import").map_err(ArchiveError::from)?;
    let result = unzip(archive, &staging).map_err(E::from).and_then(|()| read(&staging));
    let _ = fs::remove_dir_all(&staging);
    result
}

/// Checks every entry name before extracting into `into` (an empty private
/// directory), then refuses anything extracted that isn't a plain file or
/// directory.
pub fn unzip(zip: &Path, into: &Path) -> Result<(), ArchiveError> {
    if fs::metadata(zip)?.len() > MAX_ARCHIVE_BYTES {
        return Err(ArchiveError::TooLarge);
    }
    let listing = Command::new("/usr/bin/zipinfo").arg("-1").arg(zip).output()?;
    if !listing.status.success() {
        return Err(ArchiveError::Unreadable("zipinfo could not read it".to_owned()));
    }
    for name in String::from_utf8_lossy(&listing.stdout).lines() {
        if !allowed(name) {
            return Err(ArchiveError::Unsafe(name.to_owned()));
        }
    }
    let status = Command::new("/usr/bin/ditto").args(["-x", "-k"]).arg(zip).arg(into).status()?;
    if !status.success() {
        return Err(ArchiveError::Unreadable("ditto could not extract it".to_owned()));
    }
    refuse_links(into)
}

fn refuse_links(dir: &Path) -> Result<(), ArchiveError> {
    for entry in fs::read_dir(dir)?.flatten() {
        let path = entry.path();
        let kind = fs::symlink_metadata(&path)?.file_type();
        if kind.is_dir() {
            refuse_links(&path)?;
        } else if !kind.is_file() {
            return Err(ArchiveError::Unsafe(path.file_name().unwrap_or_default().to_string_lossy().into_owned()));
        }
    }
    Ok(())
}

fn is_uuid(text: &str) -> bool {
    text.len() == 36 && text.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

fn allowed(name: &str) -> bool {
    if name == "rallo-export.json" || name == "images/" {
        return true;
    }
    match name.split('/').collect::<Vec<_>>().as_slice() {
        ["images", item, ""] => is_uuid(item),
        ["images", item, file] => {
            is_uuid(item)
                && file.split_once('.').is_some_and(|(id, extension)| {
                    is_uuid(id) && matches!(extension, "png" | "jpg" | "heic" | "gif" | "webp")
                })
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ITEM: &str = "0b9c2f4e-8f7a-4c1e-9d2b-3a4e5f6a7b8c";
    const IMAGE: &str = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f";

    #[test]
    fn allowed_names() {
        assert!(allowed("rallo-export.json"));
        assert!(allowed("images/"));
        assert!(allowed(&format!("images/{ITEM}/")));
        assert!(allowed(&format!("images/{ITEM}/{IMAGE}.png")));
        for refused in [
            "../evil",
            "/etc/passwd",
            "images/../../evil.png",
            &format!("images/{ITEM}/{IMAGE}.exe"),
            &format!("images/{ITEM}/../{IMAGE}.png"),
            "notes.txt",
            "__MACOSX/._rallo-export.json",
            &format!("images/{ITEM}/sub/{IMAGE}.png"),
        ] {
            assert!(!allowed(refused), "{refused}");
        }
    }

    #[test]
    fn a_zip_round_trips() {
        let source = private_temp_dir("test-src").unwrap();
        fs::write(source.join("rallo-export.json"), b"{}").unwrap();
        fs::create_dir_all(source.join("images").join(ITEM)).unwrap();
        fs::write(source.join("images").join(ITEM).join(format!("{IMAGE}.png")), b"\x89PNG").unwrap();
        let out = source.with_extension("zip");
        zip(&source, &out).unwrap();
        assert!(is_zip(&out).unwrap());
        let target = private_temp_dir("test-dst").unwrap();
        unzip(&out, &target).unwrap();
        assert_eq!(fs::read(target.join("images").join(ITEM).join(format!("{IMAGE}.png"))).unwrap(), b"\x89PNG");
        for path in [&source, &target] {
            fs::remove_dir_all(path).unwrap();
        }
        fs::remove_file(out).unwrap();
    }

    #[test]
    fn symlink_entries_are_refused() {
        let source = private_temp_dir("test-link").unwrap();
        fs::write(source.join("rallo-export.json"), b"{}").unwrap();
        fs::create_dir_all(source.join("images").join(ITEM)).unwrap();
        std::os::unix::fs::symlink("/etc/hosts", source.join("images").join(ITEM).join(format!("{IMAGE}.png")))
            .unwrap();
        let out = source.with_extension("zip");
        zip(&source, &out).unwrap();
        let target = private_temp_dir("test-link-dst").unwrap();
        assert!(matches!(unzip(&out, &target), Err(ArchiveError::Unsafe(_))));
        for path in [&source, &target] {
            fs::remove_dir_all(path).unwrap();
        }
        fs::remove_file(out).unwrap();
    }

    #[test]
    fn a_text_file_is_not_a_zip() {
        let dir = private_temp_dir("test-notzip").unwrap();
        let path = dir.join("x.json");
        fs::write(&path, b"{}").unwrap();
        assert!(!is_zip(&path).unwrap());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn write_zip_then_read_zip_and_both_clean_up() {
        let dir = private_temp_dir("test-helpers").unwrap();
        let out = dir.join("export.zip");
        let mut staged = PathBuf::new();
        write_zip(&out, |staging| -> Result<(), ArchiveError> {
            staged = staging.to_path_buf();
            fs::write(staging.join("rallo-export.json"), b"{\"x\":1}")?;
            Ok(())
        })
        .unwrap();
        assert!(!staged.exists(), "the staging directory is removed");
        assert!(!dir.join("export.zip.partial").exists());
        assert_eq!(fs::metadata(&out).unwrap().permissions().mode() & 0o777, 0o600);
        let mut opened = PathBuf::new();
        let document = read_zip(&out, |staging| -> Result<Vec<u8>, ArchiveError> {
            opened = staging.to_path_buf();
            Ok(fs::read(staging.join("rallo-export.json"))?)
        })
        .unwrap();
        assert_eq!(document, b"{\"x\":1}");
        assert!(!opened.exists());

        let failed: Result<(), ArchiveError> = write_zip(&dir.join("never.zip"), |_| Err(ArchiveError::TooLarge));
        assert!(failed.is_err());
        assert!(!dir.join("never.zip").exists(), "a failed fill writes nothing");
        fs::remove_dir_all(dir).unwrap();
    }
}
