//! Zip archives for `export --format zip` and for importing them (0018),
//! made and opened with macOS's own `ditto`, listed with `zipinfo`. Only
//! Rallo's own layout is accepted: `rallo-export.json` and
//! `images/<uuid>/<uuid>.<ext>`.

use std::fs::{self, DirBuilder};
use std::io::{self, Read};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

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
    // macOS's clock ticks in microseconds, so the counter keeps two calls in
    // the same tick apart.
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_nanos()).unwrap_or(0);
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("rallo-{label}-{}-{nanos}-{count}", std::process::id()));
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
///
/// zipinfo reads its archive argument as a wildcard pattern (and a leading
/// `-` as options) while ditto opens it literally, so the archive is first
/// linked (or copied) to a fixed private name that both treat the same.
pub fn unzip(zip: &Path, into: &Path) -> Result<(), ArchiveError> {
    unzip_via(zip, into, &private_temp_dir("import-src")?)
}

/// Unzips through `dir`, a fresh private directory, and removes it.
fn unzip_via(zip: &Path, into: &Path, dir: &Path) -> Result<(), ArchiveError> {
    let result = unzip_private(zip, &dir.join("archive.zip"), into);
    let _ = fs::remove_dir_all(dir);
    result
}

fn unzip_private(original: &Path, zip: &Path, into: &Path) -> Result<(), ArchiveError> {
    let text = zip.to_string_lossy();
    if !zip.is_absolute() || text.starts_with('-') || text.contains(['*', '?', '[']) {
        return Err(ArchiveError::Unreadable("its working name is not safe".to_owned()));
    }
    // Copying costs disk only when the archive is on another volume.
    if fs::hard_link(original, zip).is_err() {
        fs::copy(original, zip)?;
    }
    let listing = zipinfo().arg("-1").arg(zip).output()?;
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
    let mut command = Command::new("/usr/bin/ditto");
    command.args(["-x", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"]).arg(zip).arg(into);
    // SAFETY: the closure runs between fork and exec and only calls
    // setrlimit and signal, which are async-signal-safe.
    unsafe {
        command.pre_exec(|| {
            let limit = libc::rlimit { rlim_cur: MAX_FILE_BYTES, rlim_max: MAX_FILE_BYTES };
            if libc::setrlimit(libc::RLIMIT_FSIZE, &limit) != 0 {
                return Err(io::Error::last_os_error());
            }
            // An oversized write then fails with EFBIG instead of killing ditto.
            libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
            Ok(())
        });
    }
    let allowed_total = total.saturating_add(SIZE_SLACK);
    let mut child = command.spawn()?;
    let mut last_check = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error.into());
            }
        }
        if last_check.elapsed() >= Duration::from_millis(50) {
            last_check = std::time::Instant::now();
            if dir_size(into) > allowed_total {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ArchiveError::UnpacksTooLarge("it unpacks to more than it says"));
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    if !status.success() {
        return Err(ArchiveError::Unreadable("ditto could not extract it".to_owned()));
    }
    if dir_size(into) > allowed_total {
        return Err(ArchiveError::UnpacksTooLarge("it unpacks to more than it says"));
    }
    refuse_extras(into, into)
}

/// Total size of every file under `dir`, links not followed.
fn dir_size(dir: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(dir) else { return 0 };
    entries
        .flatten()
        .map(|entry| match fs::symlink_metadata(entry.path()) {
            Ok(meta) if meta.is_dir() => dir_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .fold(0, u64::saturating_add)
}

/// A zipinfo that ignores the user's `ZIPINFO`-style options.
fn zipinfo() -> Command {
    let mut command = Command::new("/usr/bin/zipinfo");
    for name in ["ZIPINFO", "ZIPINFOOPT", "UNZIP", "UNZIPOPT"] {
        command.env_remove(name);
    }
    command
}

/// Per-file write limit for ditto: the largest allowed entry plus 1 MiB.
const MAX_FILE_BYTES: libc::rlim_t = 65 * 1024 * 1024;
/// How far past the declared total unpacking may go.
const SIZE_SLACK: u64 = 1024 * 1024;

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

/// Refuses a zip bomb before anything is written: `zipinfo -l ZIP '*'` gives
/// each entry's declared uncompressed size. With a filespec it prints entry
/// lines only (no `Archive:` header, no totals), so every non-empty line must
/// parse as an entry or the archive is refused. (Names were already checked,
/// so none contains whitespace.) The number of entries must match
/// `zipinfo -1`'s. Returns the declared total.
fn check_declared_sizes(zip: &Path, expected_entries: usize) -> Result<u64, ArchiveError> {
    let listing = zipinfo().arg("-l").arg(zip).arg("*").output()?;
    if !listing.status.success() {
        return Err(ArchiveError::Unreadable("zipinfo could not read it".to_owned()));
    }
    let mut total = 0u64;
    let mut entries = 0usize;
    for line in String::from_utf8_lossy(&listing.stdout).lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.is_empty() {
            continue;
        }
        let unreadable = || ArchiveError::Unreadable("its listing could not be checked".to_owned());
        if fields.len() < 10 || !fields[1].bytes().all(|b| b.is_ascii_digit() || b == b'.') {
            return Err(unreadable());
        }
        entries += 1;
        let size: u64 = fields[3].parse().map_err(|_| unreadable())?;
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
    fn zipinfo_ignores_the_users_options() {
        let command = zipinfo();
        let envs: Vec<_> = command.get_envs().collect();
        for name in ["ZIPINFO", "ZIPINFOOPT", "UNZIP", "UNZIPOPT"] {
            assert!(envs.contains(&(std::ffi::OsStr::new(name), None)), "{name}");
        }
    }

    #[test]
    fn a_wildcard_archive_name_cannot_swap_in_another_archive() {
        let dir = private_temp_dir("test-wild").unwrap();
        let source = dir.join("src");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("rallo-export.json"), b"{}").unwrap();
        zip(&source, &dir.join("a.zip")).unwrap();
        let bomb = bomb_named(&dir, "[a].zip");
        let target = dir.join("target");
        fs::create_dir(&target).unwrap();
        let work = private_temp_dir("test-wild-src").unwrap();
        let result = unzip_via(&bomb, &target, &work);
        assert!(matches!(result, Err(ArchiveError::UnpacksTooLarge(m)) if m.contains("10 MB")));
        assert_eq!(fs::read_dir(&target).unwrap().count(), 0, "nothing was extracted");
        assert!(!work.exists(), "the private link directory is removed");
        fs::remove_dir_all(dir).unwrap();
    }

    /// Writes a zip whose image entry really holds `mib` MiB of zeros but
    /// declares 777 bytes in both the local header and the central directory.
    fn under_declared(dir: &Path, mib: usize) -> PathBuf {
        let out = dir.join("lie.zip");
        let script = format!(
            "import sys, zipfile, struct\nz = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED)\n\
             z.writestr('images/{ITEM}/{IMAGE}.png', bytes({mib} * 1024 * 1024))\n\
             z.writestr('rallo-export.json', '{{}}')\nz.close()\n\
             d = bytearray(open(sys.argv[1], 'rb').read())\n\
             assert d[:4] == b'PK\\x03\\x04'\n\
             d[22:26] = struct.pack('<I', 777)\n\
             c = d.index(b'PK\\x01\\x02')\n\
             d[c + 24:c + 28] = struct.pack('<I', 777)\n\
             open(sys.argv[1], 'wb').write(d)\n"
        );
        let status = Command::new("/usr/bin/python3").args(["-I", "-c", &script]).arg(&out).status().unwrap();
        assert!(status.success());
        out
    }

    #[test]
    fn an_under_declared_entry_is_not_unpacked() {
        for mib in [11, 70] {
            let dir = private_temp_dir("test-lie").unwrap();
            let out = under_declared(&dir, mib);
            let staging = private_temp_dir("test-lie-staging").unwrap();
            let result = read_zip(&out, |_| -> Result<(), ArchiveError> { panic!("must not be read") });
            assert!(result.is_err(), "{mib} MiB");
            let direct = unzip(&out, &staging);
            assert!(direct.is_err(), "{mib} MiB");
            let message = direct.unwrap_err().to_string();
            assert!(
                message.contains("more than it says") || message.contains("ditto could not"),
                "{mib} MiB: {message}"
            );
            assert!(dir_size(&staging) <= 65 * 1024 * 1024, "the file limit holds");
            fs::remove_dir_all(dir).unwrap();
            fs::remove_dir_all(staging).unwrap();
        }
    }

    /// Zips an 11 MiB zero-filled image entry into `dir/<file_name>`.
    fn bomb_named(dir: &Path, file_name: &str) -> PathBuf {
        let source = dir.join("src");
        fs::create_dir_all(source.join("images").join(ITEM)).unwrap();
        fs::write(source.join("rallo-export.json"), b"{}").unwrap();
        fs::write(source.join("images").join(ITEM).join(format!("{IMAGE}.png")), vec![0u8; 11 * 1024 * 1024]).unwrap();
        let out = dir.join(file_name);
        zip(&source, &out).unwrap();
        out
    }

    #[test]
    fn an_archive_name_that_looks_like_an_entry_cannot_hide_a_bomb() {
        for file_name in ["1 2 3 4 5 6 7 8 9 10.zip", "x\n1 2 3 4 5 6 7 8 9 10.zip"] {
            let dir = private_temp_dir("test-name").unwrap();
            let out = bomb_named(&dir, file_name);
            let target = dir.join("target");
            fs::create_dir(&target).unwrap();
            assert!(matches!(unzip(&out, &target), Err(ArchiveError::UnpacksTooLarge(_))), "{file_name:?}");
            assert_eq!(fs::read_dir(&target).unwrap().count(), 0, "nothing was extracted");
            fs::remove_dir_all(dir).unwrap();
        }
    }

    /// A VMS-host entry with wide attributes: zipinfo prints it with 9 fields
    /// (no version), which the listing parser can't read.
    #[test]
    fn a_listing_line_that_cannot_be_read_refuses_the_archive() {
        // A plain name, and one whose second line looks like an entry line
        // (an old `Archive:` header counted that way balanced the count).
        for file_name in ["vms.zip", "x\n1 2 3 4 5 6 7 8 9 10.zip"] {
            let dir = private_temp_dir("test-vms").unwrap();
            let out = dir.join(file_name);
            let script = format!(
                "import sys, zipfile\nz = zipfile.ZipFile(sys.argv[1], 'w')\n\
                 i = zipfile.ZipInfo('images/{ITEM}/{IMAGE}.png')\ni.create_system = 2\n\
                 i.external_attr = 0o777 << 16\nz.writestr(i, bytes(11 * 1024 * 1024))\n\
                 z.writestr('rallo-export.json', '{{}}')\nz.close()\n"
            );
            let status = Command::new("/usr/bin/python3").args(["-I", "-c", &script]).arg(&out).status().unwrap();
            assert!(status.success());
            let target = dir.join("target");
            fs::create_dir(&target).unwrap();
            let refusal = unzip(&out, &target).unwrap_err().to_string();
            assert!(refusal.contains("listing"), "{file_name:?}: {refusal}");
            assert_eq!(fs::read_dir(&target).unwrap().count(), 0, "nothing was extracted");
            fs::remove_dir_all(dir).unwrap();
        }
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
