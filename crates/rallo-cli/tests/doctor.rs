//! Process-level tests for `rallo doctor`: a read-only health report that
//! must never create the data directory, never migrate, and never signal or
//! launch the app. Each test uses its own temporary data directory (and,
//! where the app-install/terminal-command checks matter, its own temporary
//! `$HOME`); the real data directory and `~/.local/bin` are never touched.

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use rallo_core::storage::instance_lock::InstanceLock;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

struct Cli {
    dir: tempfile::TempDir,
}

impl Cli {
    /// `data_dir()` is a not-yet-existing subdirectory of a real temp
    /// directory: `tempfile::tempdir()` itself creates its path immediately,
    /// so several tests (doctor must never create the data directory) need
    /// one more level that genuinely does not exist yet.
    fn new() -> Self {
        Self { dir: tempfile::tempdir().unwrap() }
    }

    fn data_dir(&self) -> PathBuf {
        self.dir.path().join("data")
    }

    fn db_path(&self) -> PathBuf {
        self.data_dir().join("rallo.sqlite3")
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_rallo"));
        command
            .args(args)
            .env("RALLO_DATA_DIR", self.data_dir())
            .env_remove("RALLO_APP_PATH")
            // So a real $CODEX_HOME on the machine running the tests never
            // leaks into agent_skill's Codex detection.
            .env_remove("CODEX_HOME");
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).stdin(Stdio::null()).output().unwrap()
    }

    fn json(&self, args: &[&str]) -> (i32, Value) {
        let output = self.run(args);
        (output.status.code().unwrap(), parse(&output))
    }

    fn check<'a>(doc: &'a Value, id: &str) -> &'a Value {
        doc["checks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|check| check["id"] == id)
            .unwrap_or_else(|| panic!("no {id} check in {doc}"))
    }
}

fn parse(output: &Output) -> Value {
    let stdout = String::from_utf8(output.stdout.clone()).unwrap();
    assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
    serde_json::from_str(&stdout).unwrap()
}

#[test]
fn fresh_data_dir_is_reported_as_no_data_yet_and_never_created() {
    let cli = Cli::new();
    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["ok"], true);
    assert_eq!(doc["problem_count"], 0);
    assert_eq!(doc["checks"].as_array().unwrap().len(), 9);

    let data_directory = Cli::check(&doc, "data_directory");
    assert_eq!(data_directory["status"], "ok");
    assert!(data_directory["summary"].as_str().unwrap().contains("no data yet"));

    let app_running = Cli::check(&doc, "app_running");
    assert_eq!(app_running["status"], "ok");

    assert!(!cli.data_dir().exists(), "doctor must never create the data directory");
}

#[test]
fn healthy_store_has_no_problems() {
    let cli = Cli::new();
    cli.run(&["note", "hello"]);
    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["problem_count"], 0);
    let data_directory = Cli::check(&doc, "data_directory");
    assert_eq!(data_directory["status"], "ok");
    assert!(data_directory["summary"].as_str().unwrap().contains("on disk"), "{data_directory}");
}

#[test]
fn bad_permissions_are_a_problem_with_an_exact_chmod_fix() {
    let cli = Cli::new();
    cli.run(&["note", "hello"]);
    fs::set_permissions(cli.db_path(), fs::Permissions::from_mode(0o644)).unwrap();

    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 1, "{doc}");
    assert_eq!(doc["ok"], false);
    let data_directory = Cli::check(&doc, "data_directory");
    assert_eq!(data_directory["status"], "problem");
    assert!(data_directory["fix"].as_str().unwrap().contains(&format!("chmod 600 {}", cli.db_path().display())));
}

#[test]
fn older_schema_is_reported_and_left_unmigrated() {
    let cli = Cli::new();
    fs::create_dir_all(cli.data_dir()).unwrap();
    fs::set_permissions(cli.data_dir(), fs::Permissions::from_mode(0o700)).unwrap();
    let conn = Connection::open(cli.db_path()).unwrap();
    conn.execute_batch(include_str!("../../rallo-core/src/storage/sql/0001_initial.sql")).unwrap();
    conn.pragma_update(None, "user_version", 1).unwrap();
    drop(conn);
    fs::set_permissions(cli.db_path(), fs::Permissions::from_mode(0o600)).unwrap();

    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 0, "an older schema is informational, not a problem: {doc}");
    let data_directory = Cli::check(&doc, "data_directory");
    assert_eq!(data_directory["status"], "ok");
    assert!(data_directory["summary"].as_str().unwrap().contains("will be migrated"));

    let raw = Connection::open_with_flags(cli.db_path(), OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let version: u32 = raw.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
    assert_eq!(version, 1, "doctor must never migrate");
}

#[test]
fn newer_schema_is_a_problem() {
    let cli = Cli::new();
    cli.run(&["note", "hello"]);
    let conn = Connection::open(cli.db_path()).unwrap();
    let current: u32 = conn.pragma_query_value(None, "user_version", |row| row.get(0)).unwrap();
    conn.pragma_update(None, "user_version", current + 1).unwrap();
    drop(conn);

    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 1, "{doc}");
    let data_directory = Cli::check(&doc, "data_directory");
    assert_eq!(data_directory["status"], "problem");
    assert!(data_directory["summary"].as_str().unwrap().contains("newer than this build supports"));
}

#[test]
fn reminder_capacity_warns_at_28_active_but_is_not_a_problem() {
    let cli = Cli::new();
    for i in 0..28 {
        assert_eq!(cli.run(&["remind", &format!("cap {i}"), "--in", "1h"]).status.code(), Some(0));
    }
    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 0, "a capacity warning is not a problem: {doc}");
    let reminders = Cli::check(&doc, "reminders");
    assert_eq!(reminders["status"], "warning");
    assert!(reminders["summary"].as_str().unwrap().contains("28/32"));
}

#[test]
fn unresolved_intent_stuck_while_running_warns_reminders_not_app_running() {
    let cli = Cli::new();
    cli.run(&["remind", "check the oven", "--in", "1h"]);
    let conn = Connection::open(cli.db_path()).unwrap();
    conn.execute("UPDATE notification_intents SET created_at_ms = created_at_ms - 400000", []).unwrap();
    drop(conn);

    // Hold the real OS instance lock for this data directory so the child
    // `doctor` process observes the app as running.
    let _lock = InstanceLock::try_acquire(&cli.data_dir()).unwrap().expect("nothing else holds it yet");

    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 0, "a stuck-drain warning is not a problem: {doc}");
    let reminders = Cli::check(&doc, "reminders");
    assert_eq!(reminders["status"], "warning");
    assert!(reminders["summary"].as_str().unwrap().contains("oldest"));
    let app_running = Cli::check(&doc, "app_running");
    assert_eq!(app_running["status"], "ok", "the app is running, so this is not the app_running warning");
}

#[test]
fn app_not_running_with_pending_reminder_warns_app_running() {
    let cli = Cli::new();
    cli.run(&["remind", "check the oven", "--in", "1h"]);
    let (code, doc) = cli.json(&["doctor", "--json"]);
    assert_eq!(code, 0, "{doc}");
    let app_running = Cli::check(&doc, "app_running");
    assert_eq!(app_running["status"], "warning");
    assert_eq!(app_running["fix"], "Open Rallo, or run `rallo show`.");
}

fn install_fake_app(app: &Path) {
    fs::create_dir_all(app.join("Contents/Helpers")).unwrap();
    fs::write(app.join("Contents/Info.plist"), "<plist/>").unwrap();
    let cli = app.join("Contents/Helpers/rallo");
    fs::copy(env!("CARGO_BIN_EXE_rallo"), &cli).unwrap();
    let mut permissions = fs::metadata(&cli).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&cli, permissions).unwrap();
}

#[test]
fn stale_terminal_link_from_a_moved_app_is_a_problem() {
    let cli = Cli::new();
    let root = tempfile::tempdir().unwrap();
    let root = root.path().canonicalize().unwrap();
    let home = root.join("Home With Spaces");
    let app = home.join("Applications/Rallo.app");
    install_fake_app(&app);
    let local_bin = home.join(".local/bin");
    fs::create_dir_all(&local_bin).unwrap();
    let stale_target = root.join("Volumes/Rallo/Rallo.app/Contents/Helpers/rallo");
    symlink(&stale_target, local_bin.join("rallo")).unwrap();

    let output = cli
        .command(&["doctor", "--json"])
        .env("HOME", &home)
        .env("PATH", &local_bin)
        .env("RALLO_APP_PATH", &app)
        .output()
        .unwrap();
    let doc = parse(&output);
    assert_eq!(output.status.code(), Some(1), "{doc}");
    let terminal_command = Cli::check(&doc, "terminal_command");
    assert_eq!(terminal_command["status"], "problem");
    assert_eq!(terminal_command["fix"], "rallo setup terminal");

    // `RALLO_APP_PATH` only redirects app *location*; the process actually
    // running is still the workspace's own build, a byte-identical but
    // distinct file from the fake bundle's copy, so app_install reports the
    // (harmless) embedded-CLI mismatch rather than "ok".
    let app_install = Cli::check(&doc, "app_install");
    assert_eq!(app_install["status"], "warning");
    assert!(app_install["summary"].as_str().unwrap().contains("not the one embedded"));
}

#[test]
fn terminal_command_not_enabled_yet_is_a_warning_not_a_problem() {
    let cli = Cli::new();
    let root = tempfile::tempdir().unwrap();
    let root = root.path().canonicalize().unwrap();
    let home = root.join("Home");
    let app = home.join("Applications/Rallo.app");
    install_fake_app(&app);

    let output = cli
        .command(&["doctor", "--json"])
        .env("HOME", &home)
        .env("PATH", "/usr/bin")
        .env("RALLO_APP_PATH", &app)
        .output()
        .unwrap();
    let doc = parse(&output);
    assert_eq!(output.status.code(), Some(0), "{doc}");
    let terminal_command = Cli::check(&doc, "terminal_command");
    assert_eq!(terminal_command["status"], "warning");
    assert_eq!(terminal_command["fix"], "rallo setup terminal");
}

#[test]
fn outdated_agent_skill_is_a_warning_with_the_setup_fix() {
    let cli = Cli::new();
    let home = cli.dir.path().join("home");
    let skill = home.join(".claude/skills/rallo/SKILL.md");
    fs::create_dir_all(skill.parent().unwrap()).unwrap();
    fs::write(&skill, "---\nname: rallo\ndescription: an older version\n---\n").unwrap();
    let output = cli.command(&["doctor", "--json"]).env("HOME", &home).stdin(Stdio::null()).output().unwrap();
    let agent_skill = Cli::check(&parse(&output), "agent_skill").clone();
    assert_eq!(agent_skill["status"], "warning");
    assert_eq!(agent_skill["fix"], "rallo setup skill");
}

#[test]
fn codex_current_skill_without_rules_is_a_warning_with_the_agent_fix() {
    let cli = Cli::new();
    let home = cli.dir.path().join("home");
    let install = cli
        .command(&["setup", "skill", "--json", "--agent", "codex"])
        .env("HOME", &home)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(install.status.code(), Some(0), "{}", String::from_utf8_lossy(&install.stdout));
    fs::remove_file(home.join(".codex/rules/rallo.rules")).unwrap();

    let output = cli.command(&["doctor", "--json"]).env("HOME", &home).stdin(Stdio::null()).output().unwrap();
    let agent_skill = Cli::check(&parse(&output), "agent_skill").clone();
    assert_eq!(agent_skill["status"], "warning");
    assert_eq!(agent_skill["fix"], "rallo setup skill --agent codex");
}

#[test]
fn all_current_for_claude_and_codex_reports_installed_for_both() {
    let cli = Cli::new();
    let home = cli.dir.path().join("home");
    let install = cli
        .command(&["setup", "skill", "--json", "--agent", "claude", "--agent", "codex"])
        .env("HOME", &home)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(install.status.code(), Some(0), "{}", String::from_utf8_lossy(&install.stdout));

    let output = cli.command(&["doctor", "--json"]).env("HOME", &home).stdin(Stdio::null()).output().unwrap();
    let agent_skill = Cli::check(&parse(&output), "agent_skill").clone();
    assert_eq!(agent_skill["status"], "ok");
    let summary = agent_skill["summary"].as_str().unwrap();
    assert!(summary.contains("Claude Code and Cursor"), "{summary}");
    assert!(summary.contains("Codex"), "{summary}");
    assert!(agent_skill["fix"].is_null());
}

#[test]
fn human_output_marks_every_check_and_indents_fixes() {
    let cli = Cli::new();
    let output = cli.run(&["doctor"]);
    assert!(output.status.success() || output.status.code() == Some(1));
    let stdout = String::from_utf8(output.stdout).unwrap();
    for id in [
        "app_install",
        "terminal_command",
        "agent_skill",
        "agent_hooks",
        "data_directory",
        "app_running",
        "notifications",
        "reminders",
        "backups",
    ] {
        assert!(stdout.contains(id), "{stdout:?}");
    }
    assert!(stdout.lines().all(|line| line.starts_with('[') || line.trim_start().starts_with("fix:")));
}
