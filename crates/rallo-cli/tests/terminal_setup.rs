//! Process-level tests for `rallo setup terminal` against a temporary $HOME
//! and a fake installed-app layout, so the real ~/.local/bin is never
//! touched. Scenarios mirror `TerminalCommandTests.swift`.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use serde_json::Value;

struct Setup {
    // Kept only so the directory outlives the test; walk it via `root`.
    _root_dir: tempfile::TempDir,
    // Canonical: `setup terminal` resolves its own executable's real path
    // (following symlinks), and `/tmp`/`TMPDIR` are themselves symlinks on
    // macOS, so a non-canonical fixture path would fail `is_installed`
    // purely on that mismatch rather than on anything the test cares about.
    root: PathBuf,
    home: PathBuf,
    app: PathBuf,
    cli: PathBuf,
}

impl Setup {
    /// `<home>/Applications/Rallo.app` with a copy of the real built CLI at
    /// `Contents/Helpers/rallo` -- the same layout as an installed app, so
    /// `setup terminal`'s own executable-path resolution behaves exactly as
    /// it would for a real user. The home directory name has a space in it
    /// throughout, on purpose.
    fn new() -> Self {
        let root_dir = tempfile::tempdir().unwrap();
        let root = root_dir.path().canonicalize().unwrap();
        let home = root.join("Home With Spaces");
        let app = home.join("Applications/Rallo.app");
        let cli = install_cli(&app);
        Self { _root_dir: root_dir, root, home, app, cli }
    }

    /// A copy of the app running from outside any Applications folder.
    fn not_installed() -> Self {
        let root_dir = tempfile::tempdir().unwrap();
        let root = root_dir.path().canonicalize().unwrap();
        let home = root.join("Home With Spaces");
        fs::create_dir_all(&home).unwrap();
        let app = root.join("Downloads/Rallo.app");
        let cli = install_cli(&app);
        Self { _root_dir: root_dir, root, home, app, cli }
    }

    fn local_bin(&self) -> PathBuf {
        self.home.join(".local/bin")
    }

    fn bin(&self) -> PathBuf {
        self.home.join("bin")
    }

    fn command(&self, path: &str) -> Command {
        let mut command = Command::new(&self.cli);
        command
            .args(["setup", "terminal", "--json"])
            .env("HOME", &self.home)
            .env("PATH", path)
            .env("SHELL", "/bin/zsh")
            .env_remove("RALLO_APP_PATH")
            .env_remove("RALLO_DATA_DIR");
        command
    }

    fn run(&self, path: &str) -> Output {
        self.command(path).output().unwrap()
    }

    fn json(&self, path: &str) -> (i32, Value) {
        let output = self.run(path);
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
        (output.status.code().unwrap(), serde_json::from_str(&stdout).unwrap())
    }
}

fn install_cli(app: &Path) -> PathBuf {
    let helpers = app.join("Contents/Helpers");
    fs::create_dir_all(&helpers).unwrap();
    let cli = helpers.join("rallo");
    fs::copy(env!("CARGO_BIN_EXE_rallo"), &cli).unwrap();
    let mut permissions = fs::metadata(&cli).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&cli, permissions).unwrap();
    cli
}

fn path_with(dirs: &[&Path]) -> String {
    dirs.iter().map(|dir| dir.to_string_lossy().into_owned()).collect::<Vec<_>>().join(":")
}

#[test]
fn fresh_install_enables_into_local_bin() {
    let setup = Setup::new();
    let path = path_with(&[&setup.local_bin(), Path::new("/usr/bin")]);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["ok"], true);
    assert_eq!(doc["terminal"]["status"], "enabled");
    assert_eq!(doc["terminal"]["on_path"], true);
    let link = setup.local_bin().join("rallo");
    assert_eq!(fs::read_link(&link).unwrap(), setup.app.join("Contents/Helpers/rallo"));

    // The link actually resolves and runs -- the whole point of this command.
    let version = Command::new(&link).arg("--version").output().unwrap();
    assert!(version.status.success());
}

#[test]
fn already_enabled_is_reported_and_idempotent() {
    let setup = Setup::new();
    let path = path_with(&[&setup.local_bin()]);
    assert_eq!(setup.json(&path).0, 0);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 0);
    assert_eq!(doc["terminal"]["status"], "already_enabled");
    assert_eq!(doc["terminal"]["on_path"], true);
}

#[test]
fn repairs_a_link_left_by_a_moved_app() {
    let setup = Setup::new();
    fs::create_dir_all(setup.local_bin()).unwrap();
    let stale = setup.root.join("Volumes/Rallo/Rallo.app/Contents/Helpers/rallo");
    symlink(&stale, setup.local_bin().join("rallo")).unwrap();
    let path = path_with(&[&setup.local_bin()]);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["terminal"]["status"], "repaired");
    assert_eq!(fs::read_link(setup.local_bin().join("rallo")).unwrap(), setup.app.join("Contents/Helpers/rallo"));
}

#[test]
fn never_replaces_a_foreign_rallo() {
    let setup = Setup::new();
    fs::create_dir_all(setup.local_bin()).unwrap();
    fs::write(setup.local_bin().join("rallo"), "someone else's tool").unwrap();
    let path = path_with(&[&setup.local_bin()]);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 4);
    assert_eq!(doc["ok"], false);
    assert_eq!(doc["error"]["code"], "TERMINAL_COMMAND_CONFLICT");
    assert_eq!(fs::read_to_string(setup.local_bin().join("rallo")).unwrap(), "someone else's tool");
}

#[test]
fn detects_an_earlier_conflicting_rallo_on_path() {
    let setup = Setup::new();
    let earlier = setup.root.join("tools");
    fs::create_dir_all(&earlier).unwrap();
    fs::write(earlier.join("rallo"), "").unwrap();
    let path = path_with(&[&earlier, &setup.local_bin()]);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 4);
    assert_eq!(doc["error"]["code"], "TERMINAL_COMMAND_CONFLICT");
}

#[test]
fn app_outside_applications_is_a_clear_error_not_a_conflict() {
    let setup = Setup::not_installed();
    let path = path_with(&[&setup.local_bin()]);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 2);
    assert_eq!(doc["ok"], false);
    assert_eq!(doc["error"]["code"], "NOT_INSTALLED");
}

#[test]
fn off_path_enables_and_adds_the_directory_to_the_login_profile() {
    let setup = Setup::new();
    let (code, doc) = setup.json("/usr/bin");
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["terminal"]["status"], "enabled");
    assert_eq!(doc["terminal"]["on_path"], false);
    let profile = setup.home.join(".zprofile");
    assert_eq!(doc["terminal"]["profile_updated"], profile.to_string_lossy().as_ref());
    assert!(doc["warnings"].as_array().unwrap().is_empty(), "{doc}");
    let text = fs::read_to_string(&profile).unwrap();
    assert!(text.contains(r#"export PATH="$HOME/.local/bin:$PATH""#), "{text}");

    // Still off PATH in this (old) terminal, but the profile isn't written twice.
    let (_, again) = setup.json("/usr/bin");
    assert_eq!(again["terminal"]["profile_updated"], Value::Null);
    assert_eq!(fs::read_to_string(&profile).unwrap(), text);
}

#[test]
fn falls_back_to_bin_when_it_is_already_on_path() {
    let setup = Setup::new();
    let path = path_with(&[&setup.bin()]);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["terminal"]["link"], setup.bin().join("rallo").to_string_lossy().as_ref());
    assert_eq!(doc["terminal"]["on_path"], true);
}

#[test]
fn a_home_path_with_spaces_resolves_and_the_link_runs() {
    let setup = Setup::new();
    assert!(setup.home.to_string_lossy().contains(' '), "fixture home should contain a space");
    let path = path_with(&[&setup.local_bin()]);
    let (code, doc) = setup.json(&path);
    assert_eq!(code, 0, "{doc}");
    let link = PathBuf::from(doc["terminal"]["link"].as_str().unwrap());
    let output = Command::new(&link).arg("--version").output().unwrap();
    assert!(output.status.success());
}

/// A stand-in login shell: ignores `-lc …` and prints `path` as its PATH, so
/// the non-interactive check never runs the real user's shell config.
fn stub_shell(root: &Path, path: &str) -> PathBuf {
    let shell = root.join("stub-shell");
    fs::write(&shell, format!("#!/bin/sh\nprintf '%s' '{path}'\n")).unwrap();
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o755)).unwrap();
    shell
}

#[test]
fn a_link_missing_from_non_interactive_shells_gets_a_profile_fix() {
    let setup = Setup::new();
    let path = format!("{}:/usr/bin:/bin", setup.local_bin().display());
    let shell = stub_shell(&setup.root, "/usr/bin:/bin");
    let output = setup.command(&path).env("SHELL", &shell).output().unwrap();
    let json: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(output.status.code(), Some(0));
    let fix = json["terminal"]["noninteractive_fix"].as_str().expect("a fix is offered");
    assert!(fix.contains(r#"export PATH="$HOME/.local/bin:$PATH""#), "{fix}");
    assert!(fix.ends_with("~/.profile"), "a non-zsh/bash shell uses ~/.profile: {fix}");
}

#[test]
fn a_link_on_every_shells_path_needs_no_profile_fix() {
    let setup = Setup::new();
    let path = format!("{}:/usr/bin:/bin", setup.local_bin().display());
    let shell = stub_shell(&setup.root, &path);
    let output = setup.command(&path).env("SHELL", &shell).output().unwrap();
    let json: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(output.status.code(), Some(0));
    assert!(json["terminal"]["noninteractive_fix"].is_null());
}
