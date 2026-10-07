//! Process-level tests for `rallo uninstall`, against a fake installed app
//! in a temporary HOME. The app-owned cleanup (`Contents/MacOS/Rallo
//! --prepare-uninstall`) is a shell script here and only runs under the
//! test-only `RALLO_UNINSTALL_TEST_PREPARE=1`: the real one would touch the
//! real notifications, Login Items and Keychain, which belong to the bundle
//! ID rather than to any data directory.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use rusqlite::Connection;
use serde_json::Value;

const RESTRICTED_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";
const MARKER_LINE: &str = "# Added by Rallo so the `rallo` command is found (rallo setup terminal).";

struct Fixture {
    _root: tempfile::TempDir,
    home: PathBuf,
    app: PathBuf,
    cli: PathBuf,
    data_dir: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root_dir = tempfile::tempdir().unwrap();
        let root = root_dir.path().canonicalize().unwrap();
        let home = root.join("Home");
        let app = home.join("Applications/Rallo.app");
        let helpers = app.join("Contents/Helpers");
        fs::create_dir_all(&helpers).unwrap();
        fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        fs::write(app.join("Contents/Info.plist"), "<plist/>").unwrap();
        let cli = helpers.join("rallo");
        fs::copy(env!("CARGO_BIN_EXE_rallo"), &cli).unwrap();
        fs::set_permissions(&cli, fs::Permissions::from_mode(0o755)).unwrap();
        let data_dir = root.join("data");
        Self { _root: root_dir, home, app, cli, data_dir }
    }

    fn fake_app_script(&self, body: &str) {
        let path = self.app.join("Contents/MacOS/Rallo");
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(&self.cli);
        command
            .args(args)
            .env("HOME", &self.home)
            .env("PATH", RESTRICTED_PATH)
            .env("RALLO_DATA_DIR", &self.data_dir)
            .env_remove("RALLO_APP_PATH")
            .env_remove("CODEX_HOME")
            .env_remove("GROK_HOME")
            .env_remove("GEMINI_CLI_HOME")
            .env_remove("RALLO_UNINSTALL_TEST_PREPARE")
            .stdin(Stdio::null());
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().unwrap()
    }

    fn json(&self, args: &[&str]) -> (i32, Value) {
        json_of(self.run(args))
    }

    fn db(&self) -> PathBuf {
        self.data_dir.join("rallo.sqlite3")
    }
}

fn json_of(output: Output) -> (i32, Value) {
    let stdout = String::from_utf8(output.stdout).unwrap();
    (output.status.code().unwrap(), serde_json::from_str(&stdout).unwrap_or_else(|_| panic!("not JSON: {stdout:?}")))
}

#[test]
fn outside_an_installed_app_it_refuses() {
    let home = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rallo"))
        .args(["uninstall", "--yes", "--json"])
        .env("HOME", home.path())
        .env("PATH", RESTRICTED_PATH)
        .env_remove("RALLO_APP_PATH")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let (code, doc) = json_of(output);
    assert_eq!(code, 2, "{doc}");
    assert_eq!(doc["error"]["code"], "NOT_INSTALLED");
}

#[test]
fn without_yes_and_without_a_terminal_it_asks_for_yes() {
    let fixture = Fixture::new();
    let (code, doc) = fixture.json(&["uninstall", "--json"]);
    assert_eq!(code, 2, "{doc}");
    assert_eq!(doc["error"]["code"], "CONFIRMATION_REQUIRED");
    assert!(fixture.app.exists(), "nothing was removed");
}

#[test]
fn keeps_notes_and_removes_only_rallos_own_files() {
    let fixture = Fixture::new();
    let home = &fixture.home;
    assert!(fixture.run(&["note", "keep me"]).status.success());

    // Hooks: Rallo's own plus a foreign Stop hook in the same file.
    assert!(fixture.run(&["setup", "hooks", "--agent", "claude"]).status.success());
    let settings = home.join(".claude/settings.json");
    let mut doc: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    doc["hooks"]["Stop"]
        .as_array_mut()
        .unwrap()
        .push(serde_json::json!({"hooks": [{"type": "command", "command": "echo foreign"}]}));
    fs::write(&settings, serde_json::to_string_pretty(&doc).unwrap()).unwrap();

    // Skills: Rallo's own for Claude, someone else's for Codex; Rallo's rules.
    assert!(fixture.run(&["setup", "skill", "--agent", "claude"]).status.success());
    let claude_skill = home.join(".claude/skills/rallo/SKILL.md");
    assert!(claude_skill.exists());
    let codex_skill = home.join(".codex/skills/rallo/SKILL.md");
    fs::create_dir_all(codex_skill.parent().unwrap()).unwrap();
    fs::write(&codex_skill, "my own skill").unwrap();
    let rules = home.join(".codex/rules/rallo.rules");
    fs::create_dir_all(rules.parent().unwrap()).unwrap();
    fs::write(&rules, "# Rallo 0.0.1: written by `rallo setup skill`. old\n").unwrap();

    // Links: Rallo's own, and another tool's `rallo`.
    let link = home.join(".local/bin/rallo");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    symlink(&fixture.cli, &link).unwrap();
    let foreign = home.join("bin/rallo");
    fs::create_dir_all(foreign.parent().unwrap()).unwrap();
    symlink("/usr/bin/true", &foreign).unwrap();

    let profile = home.join(".zprofile");
    let profile_text = format!("echo hi\n\n{MARKER_LINE}\nexport PATH=\"$HOME/.local/bin:$PATH\"\n");
    fs::write(&profile, &profile_text).unwrap();

    let (code, doc) = fixture.json(&["uninstall", "--yes", "--json"]);
    assert_eq!(code, 0, "{doc}");
    let report = &doc["uninstall"];
    assert_eq!(report["data"], "kept");
    assert_eq!(report["prepared"], Value::Null);
    assert_eq!(report["export_path"], Value::Null);
    assert_eq!(report["path_line_kept"], profile.to_str().unwrap());

    assert!(!fixture.app.exists());
    assert!(link.symlink_metadata().is_err());
    assert_eq!(fs::read_link(&foreign).unwrap(), Path::new("/usr/bin/true"));
    let remaining = fs::read_to_string(&settings).unwrap();
    assert!(remaining.contains("echo foreign"), "{remaining}");
    assert!(!remaining.contains("agent-event"), "{remaining}");
    assert!(!claude_skill.exists());
    assert!(!claude_skill.parent().unwrap().exists(), "the empty skill directory goes too");
    assert!(!rules.exists());
    assert_eq!(fs::read_to_string(&codex_skill).unwrap(), "my own skill");
    assert!(fixture.db().exists(), "notes kept");
    assert_eq!(fs::read_to_string(&profile).unwrap(), profile_text);
}

#[test]
fn purge_saves_an_export_then_deletes_the_data() {
    let fixture = Fixture::new();
    assert!(fixture.run(&["note", "remember the milk"]).status.success());
    let (code, doc) = fixture.json(&["uninstall", "--yes", "--purge", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["uninstall"]["data"], "deleted");
    let export = PathBuf::from(doc["uninstall"]["export_path"].as_str().unwrap());
    assert_eq!(export.parent().unwrap(), fixture.home.join("Downloads"));
    assert_eq!(export.extension().unwrap(), "zip");
    let document = std::process::Command::new("/usr/bin/unzip").arg("-p").arg(&export).output().unwrap();
    assert!(String::from_utf8_lossy(&document.stdout).contains("remember the milk"));
    assert!(!fixture.data_dir.exists());
    assert!(!fixture.app.exists());
}

#[test]
fn purge_with_an_unreadable_store_removes_nothing() {
    let fixture = Fixture::new();
    assert!(fixture.run(&["note", "precious"]).status.success());
    let conn = Connection::open(fixture.db()).unwrap();
    let current: u32 = conn.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
    conn.pragma_update(None, "user_version", current + 1).unwrap();
    drop(conn);

    let (code, doc) = fixture.json(&["uninstall", "--yes", "--purge", "--json"]);
    assert_eq!(code, 5, "{doc}");
    assert_eq!(doc["error"]["code"], "UNINSTALL_EXPORT_FAILED");
    assert!(fixture.app.exists());
    assert!(fixture.db().exists());
}

#[test]
fn purge_fails_cleanly_when_the_zip_cannot_be_written() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new();
    assert!(fixture.run(&["note", "precious"]).status.success());
    let downloads = fixture.home.join("Downloads");
    fs::create_dir_all(&downloads).unwrap();
    fs::set_permissions(&downloads, fs::Permissions::from_mode(0o500)).unwrap();
    let (code, doc) = fixture.json(&["uninstall", "--yes", "--purge", "--json"]);
    fs::set_permissions(&downloads, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(code, 5, "{doc}");
    assert_eq!(doc["error"]["code"], "UNINSTALL_EXPORT_FAILED");
    assert!(doc["error"]["message"].as_str().unwrap().starts_with("couldn't save a final export"));
    assert!(fixture.app.exists());
    assert!(fixture.db().exists());
}

#[test]
fn the_apps_cleanup_report_is_passed_through() {
    let fixture = Fixture::new();
    fixture.fake_app_script(
        "[ \"$1\" = --prepare-uninstall ] || exit 9\n\
         printf '%s' '{\"login_item\":\"failed\",\"notifications_removed\":3,\"clickup_token\":\"removed\"}'",
    );
    let mut command = fixture.command(&["uninstall", "--yes", "--json"]);
    command.env("RALLO_UNINSTALL_TEST_PREPARE", "1");
    let (code, doc) = json_of(command.output().unwrap());
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["uninstall"]["prepared"]["notifications_removed"], 3);
    assert_eq!(doc["uninstall"]["prepared"]["login_item"], "failed");
    let warnings = doc["warnings"].as_array().unwrap();
    assert!(warnings.iter().any(|w| w.as_str().unwrap().contains("Login Items")), "{doc}");
    assert!(!fixture.app.exists());
}

#[test]
fn a_failing_cleanup_removes_nothing() {
    let fixture = Fixture::new();
    fixture.fake_app_script("exit 1");
    let mut command = fixture.command(&["uninstall", "--yes", "--json"]);
    command.env("RALLO_UNINSTALL_TEST_PREPARE", "1");
    let (code, doc) = json_of(command.output().unwrap());
    assert_eq!(code, 6, "{doc}");
    assert_eq!(doc["error"]["code"], "UNINSTALL_PREPARE_FAILED");
    assert!(fixture.app.exists());
}
