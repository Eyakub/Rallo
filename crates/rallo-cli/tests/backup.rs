//! Process-level tests for `rallo backup`: a consistent SQLite snapshot that
//! must work while another connection holds the database open, never starts
//! the app, and never overwrites an existing file without `--force`. Each
//! test uses its own temporary data directory.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

use rusqlite::Connection;
use serde_json::Value;

struct Cli {
    dir: tempfile::TempDir,
}

impl Cli {
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
        command.args(args).env("RALLO_DATA_DIR", self.data_dir()).env_remove("RALLO_APP_PATH");
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).stdin(Stdio::null()).output().unwrap()
    }

    fn json(&self, args: &[&str]) -> (i32, Value) {
        let output = self.run(args);
        (output.status.code().unwrap(), parse(&output))
    }
}

fn parse(output: &Output) -> Value {
    let stdout = String::from_utf8(output.stdout.clone()).unwrap();
    assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
    serde_json::from_str(&stdout).unwrap()
}

fn mode_of(path: &std::path::Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn default_path_is_mode_0600_under_the_backups_directory() {
    let cli = Cli::new();
    cli.run(&["note", "hello"]);
    let (code, doc) = cli.json(&["backup", "--json"]);
    assert_eq!(code, 0, "{doc}");
    let path = PathBuf::from(doc["backup"]["path"].as_str().unwrap());
    // `Store::data_dir()` is canonicalized; `cli.data_dir()` is the raw
    // `RALLO_DATA_DIR` value, which differs on macOS where `$TMPDIR` is
    // itself a symlink (`/var` -> `/private/var`).
    assert_eq!(path.parent().unwrap(), cli.data_dir().canonicalize().unwrap().join("backups"));
    assert!(path.file_name().unwrap().to_str().unwrap().starts_with("manual-"));
    assert!(path.exists());
    assert_eq!(mode_of(&path), 0o600);
    assert_eq!(doc["backup"]["bytes"].as_u64().unwrap(), std::fs::metadata(&path).unwrap().len());
}

#[test]
fn never_starts_the_app() {
    let cli = Cli::new();
    cli.run(&["note", "hello"]);
    let (code, doc) = cli.json(&["backup", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["warnings"], serde_json::json!([]), "no launch attempt, so no launch-failure warning either");
}

#[test]
fn refuses_to_overwrite_without_force_but_force_replaces() {
    let cli = Cli::new();
    cli.run(&["note", "first"]);
    let out_dir = tempfile::tempdir().unwrap();
    let path = out_dir.path().join("snapshot.sqlite3");

    assert!(cli.run(&["backup", "--output", path.to_str().unwrap()]).status.success());

    let (code, doc) = cli.json(&["backup", "--output", path.to_str().unwrap(), "--json"]);
    assert_eq!(code, 4, "FILE_EXISTS is a conflict, not a usage error");
    assert_eq!(doc["error"]["code"], "FILE_EXISTS");

    cli.run(&["note", "second"]);
    let (code, doc) = cli.json(&["backup", "--output", path.to_str().unwrap(), "--force", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(mode_of(&path), 0o600);
}

#[test]
fn backup_is_restorable_and_readable() {
    let cli = Cli::new();
    let (_, note) = cli.json(&["note", "restore me please", "--json"]);
    let out_dir = tempfile::tempdir().unwrap();
    let path = out_dir.path().join("snapshot.sqlite3");
    assert!(cli.run(&["backup", "--output", path.to_str().unwrap()]).status.success());

    let conn = Connection::open(&path).unwrap();
    let text: String = conn
        .query_row("SELECT text FROM items WHERE id = ?1", [note["item"]["id"].as_str().unwrap()], |row| row.get(0))
        .unwrap();
    assert_eq!(text, "restore me please");
}

#[test]
fn works_while_another_connection_holds_a_read_transaction() {
    let cli = Cli::new();
    cli.run(&["note", "hello"]);

    // Simulate the app's own open connection reading the store concurrently:
    // the online backup API must not hang against it (0004's finding).
    let reader = Connection::open(cli.db_path()).unwrap();
    let tx = reader.unchecked_transaction().unwrap();
    let _rows: i64 = tx.query_row("SELECT COUNT(*) FROM items", [], |row| row.get(0)).unwrap();

    let (code, doc) = cli.json(&["backup", "--json"]);
    assert_eq!(code, 0, "{doc}");

    tx.rollback().unwrap();
}

#[test]
fn is_a_read_command_never_migrating_or_mutating_the_live_store() {
    let cli = Cli::new();
    let (_, note) = cli.json(&["note", "unaffected", "--json"]);
    let before = note["item"]["revision"].as_i64().unwrap();

    cli.run(&["backup"]);

    let (_, got) = cli.json(&["get", note["item"]["id"].as_str().unwrap(), "--json"]);
    assert_eq!(got["item"]["revision"].as_i64().unwrap(), before, "backup must not change the live store");
}
