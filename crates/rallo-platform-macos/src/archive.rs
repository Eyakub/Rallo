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

const MAX_ENTRIES: usize = 100_000;
/// Free space that must remain after unpacking.
const FREE_SPACE_MARGIN: u64 = 512 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum ArchiveError {
    #[error("{0}")]
    Io(#[from] io::Error),
    #[error("not a Rallo archive: {0}")]
    Unreadable(String),
    #[error("not a Rallo archive: it contains \"{0}\"")]
    Unsafe(String),
    #[error("not enough free space to unpack this archive: it needs {0} MB")]
    NoSpace(u64),
    #[error("the archive unpacks to more than Rallo accepts: {0}")]
    UnpacksTooLarge(&'static str),
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
    let listing = Command::new("/usr/bin/zipinfo").arg("-1").arg(zip).output()?;
    if !listing.status.success() {
        return Err(ArchiveError::Unreadable("zipinfo could not read it".to_owned()));
    }
    let names = String::from_utf8_lossy(&listing.stdout);
    let mut count = 0usize;
    for name in names.lines() {
        if !allowed(name) {
            return Err(ArchiveError::Unsafe(name.to_owned()));
        }
        count += 1;
        if count > MAX_ENTRIES {
            return Err(ArchiveError::Unreadable("it has more than 100000 entries".to_owned()));
        }
    }
    let total = check_declared_sizes(zip, count)?;
    let free = free_space(into)?;
    if !fits(total, free) {
        return Err(ArchiveError::NoSpace(total.saturating_add(FREE_SPACE_MARGIN) / (1024 * 1024)));
    }
    let status = Command::new("/usr/bin/ditto")
        .args(["-x", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"])
        .arg(zip)
        .arg(into)
        .status()?;
    if !status.success() {
        return Err(ArchiveError::Unreadable("ditto could not extract it".to_owned()));
    }
    refuse_extras(into, into)
}

const MAX_IMAGE_ENTRY_BYTES: u64 = 10 * 1024 * 1024;
const MAX_DOCUMENT_ENTRY_BYTES: u64 = 64 * 1024 * 1024;

/// Whether `total` unpacked bytes fit in `free` bytes with the margin to spare.
fn fits(total: u64, free: u64) -> bool {
    total.saturating_add(FREE_SPACE_MARGIN) <= free
}

/// Free bytes (for unprivileged users) on the volume holding `dir`.
fn free_space(dir: &Path) -> io::Result<u64> {
    let path = std::ffi::CString::new(dir.as_os_str().as_encoded_bytes()).map_err(io::Error::other)?;
    let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: `path` is a valid C string and `stats` is a writable statvfs.
    if unsafe { libc::statvfs(path.as_ptr(), stats.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: statvfs succeeded, so it filled `stats`.
    let stats = unsafe { stats.assume_init() };
    Ok(u64::from(stats.f_bavail).saturating_mul(stats.f_frsize))
}

/// Refuses a zip bomb before anything is written: `zipinfo -l` gives each
/// entry's declared uncompressed size. (Names were already checked, so none
/// contains whitespace.) Every entry line counts whatever its mode (zips
/// from Python carry no type bits), and the number of entries must match
/// `zipinfo -1`'s. Returns the declared total.
fn check_declared_sizes(zip: &Path, expected_entries: usize) -> Result<u64, ArchiveError> {
    let listing = Command::new("/usr/bin/zipinfo").arg("-l").arg(zip).output()?;
    if !listing.status.success() {
        return Err(ArchiveError::Unreadable("zipinfo could not read it".to_owned()));
    }
    let mut total = 0u64;
    let mut entries = 0usize;
    for line in String::from_utf8_lossy(&listing.stdout).lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let is_entry = fields.len() >= 10
            && fields[3].bytes().all(|b| b.is_ascii_digit())
            && fields[1].bytes().all(|b| b.is_ascii_digit() || b == b'.');
        if !is_entry {
            continue; // header and summary lines
        }
        entries += 1;
        let size: u64 =
            fields[3].parse().map_err(|_| ArchiveError::Unreadable("a bad size in its listing".to_owned()))?;
        let name = fields[9..].join(" ");
        if name.starts_with("images/") && size > MAX_IMAGE_ENTRY_BYTES {
            return Err(ArchiveError::UnpacksTooLarge("an image in it is over 10 MB"));
        }
        if name == "rallo-export.json" && size > MAX_DOCUMENT_ENTRY_BYTES {
            return Err(ArchiveError::UnpacksTooLarge("its rallo-export.json is over 64 MB"));
        }
        total = total.saturating_add(size);
    }
    if entries != expected_entries {
        return Err(ArchiveError::Unreadable("its listing could not be checked".to_owned()));
    }
    Ok(total)
}

/// Walks what was extracted (ditto uses the local headers' names, not the
/// listing's): only plain files and directories, and only names `allowed`.
fn refuse_extras(root: &Path, dir: &Path) -> Result<(), ArchiveError> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let kind = fs::symlink_metadata(&path)?.file_type();
        let mut name = path.strip_prefix(root).unwrap_or(&path).to_string_lossy().into_owned();
        if kind.is_dir() {
            name.push('/');
        }
        if !(kind.is_dir() || kind.is_file()) || !allowed(&name) {
            return Err(ArchiveError::Unsafe(name));
        }
        if kind.is_dir() {
            refuse_extras(root, &path)?;
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
    fn a_zip_bomb_is_refused_before_anything_is_written() {
        let source = private_temp_dir("test-bomb").unwrap();
        fs::write(source.join("rallo-export.json"), b"{}").unwrap();
        fs::create_dir_all(source.join("images").join(ITEM)).unwrap();
        fs::write(source.join("images").join(ITEM).join(format!("{IMAGE}.png")), vec![0u8; 11 * 1024 * 1024]).unwrap();
        let out = source.with_extension("zip");
        zip(&source, &out).unwrap();
        let target = private_temp_dir("test-bomb-dst").unwrap();
        assert!(matches!(unzip(&out, &target), Err(ArchiveError::UnpacksTooLarge(_))));
        assert_eq!(fs::read_dir(&target).unwrap().count(), 0, "nothing was extracted");
        for path in [&source, &target] {
            fs::remove_dir_all(path).unwrap();
        }
        fs::remove_file(out).unwrap();
    }

    #[test]
    fn free_space_comparison() {
        assert!(fits(0, FREE_SPACE_MARGIN));
        assert!(!fits(1, FREE_SPACE_MARGIN));
        assert!(fits(1 << 40, (1 << 40) + FREE_SPACE_MARGIN));
        assert!(!fits(u64::MAX, u64::MAX - 1));
        assert!(free_space(&std::env::temp_dir()).unwrap() > 0);
    }

    #[test]
    fn a_bomb_in_a_zip_without_type_bits_is_refused() {
        let dir = private_temp_dir("test-pybomb").unwrap();
        let out = dir.join("bomb.zip");
        let script = format!(
            "import sys, zipfile\nz = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED)\n\
             z.writestr('rallo-export.json', '{{}}')\n\
             z.writestr('images/{ITEM}/{IMAGE}.png', bytes(11 * 1024 * 1024))\nz.close()\n"
        );
        let status = Command::new("/usr/bin/python3").args(["-I", "-c", &script]).arg(&out).status().unwrap();
        assert!(status.success());
        let target = dir.join("target");
        fs::create_dir(&target).unwrap();
        assert!(matches!(unzip(&out, &target), Err(ArchiveError::UnpacksTooLarge(_))));
        assert_eq!(fs::read_dir(&target).unwrap().count(), 0, "nothing was extracted");
        fs::remove_dir_all(dir).unwrap();
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

        let failed: Result<(), ArchiveError> =
            write_zip(&dir.join("never.zip"), |_| Err(ArchiveError::Unreadable("x".to_owned())));
        assert!(failed.is_err());
        assert!(!dir.join("never.zip").exists(), "a failed fill writes nothing");
        fs::remove_dir_all(dir).unwrap();
    }
}
