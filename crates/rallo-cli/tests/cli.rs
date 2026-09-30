//! Process-level CLI contract tests: stdout/stderr separation, exit codes,
//! stdin handling, and JSON validity. Each test uses its own data directory.

use std::io::Write;
use std::process::{Command, Output, Stdio};

use serde_json::Value;

struct Cli {
    dir: tempfile::TempDir,
}

impl Cli {
    fn new() -> Self {
        let cli = Self { dir: tempfile::tempdir().unwrap() };
        // Hidden notes never try to launch the app.
        assert!(cli.run(&["hide"]).status.success());
        cli
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_rallo"));
        command.args(args).env("RALLO_DATA_DIR", self.dir.path()).env_remove("RALLO_APP_PATH");
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).stdin(Stdio::null()).output().unwrap()
    }

    fn run_stdin(&self, args: &[&str], input: &[u8]) -> Output {
        let mut child =
            self.command(args).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        child.wait_with_output().unwrap()
    }

    fn json(&self, args: &[&str]) -> (i32, Value) {
        let output = self.run(args);
        (output.status.code().unwrap(), parse(&output))
    }
}

fn parse(output: &Output) -> Value {
    let stdout = String::from_utf8(output.stdout.clone()).unwrap();
    assert!(!stdout.contains('\u{1b}'), "JSON stdout must not contain ANSI escapes");
    assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
    serde_json::from_str(&stdout).unwrap()
}

#[test]
fn note_json_contract() {
    let cli = Cli::new();
    let (code, doc) = cli.json(&["note", "Investigate the flaky test", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["schema_version"], 1);
    assert_eq!(doc["ok"], true);
    assert_eq!(doc["item"]["text"], "Investigate the flaky test");
    assert_eq!(doc["item"]["status"], "open");
    assert_eq!(doc["item"]["revision"], 1);
    assert!(doc["scheduling"].is_null());
    assert_eq!(doc["warnings"], serde_json::json!([]));
    uuid_like(doc["item"]["id"].as_str().unwrap());
}

#[test]
fn stdin_preserves_content_and_drops_one_trailing_newline() {
    let cli = Cli::new();
    let text = "line one\n\n  line two with $(not a command) and 'quotes'\n";
    let output = cli.run_stdin(&["note", "--stdin", "--json"], text.as_bytes());
    assert!(output.status.success());
    assert_eq!(parse(&output)["item"]["text"], "line one\n\n  line two with $(not a command) and 'quotes'");
}

#[test]
fn invalid_input_fails_before_commit_with_exit_2() {
    let cli = Cli::new();
    let (code, doc) = cli.json(&["note", "  \t ", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(doc["ok"], false);
    assert_eq!(doc["error"]["code"], "TEXT_EMPTY");

    let oversized = vec![b'a'; 64 * 1024 + 3];
    let output = cli.run_stdin(&["note", "--stdin", "--json"], &oversized);
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(parse(&output)["error"]["code"], "TEXT_TOO_LONG");

    let output = cli.run_stdin(&["note", "--stdin", "--json"], &[0xff, 0xfe]);
    assert_eq!(output.status.code(), Some(2));

    let (_, list) = cli.json(&["list", "--json"]);
    assert_eq!(list["items"], serde_json::json!([]), "nothing was committed");
}

#[test]
fn text_and_stdin_conflict_and_missing_command_are_usage_errors() {
    let cli = Cli::new();
    assert_eq!(cli.run(&["note", "x", "--stdin"]).status.code(), Some(2));
    let output = cli.run(&["--json"]);
    assert_eq!(output.status.code(), Some(2));
    let doc = parse(&output);
    assert_eq!(doc["ok"], false);
    assert!(!output.stderr.is_empty(), "help goes to stderr");
}

#[test]
fn human_output_sanitises_terminal_control_characters() {
    let cli = Cli::new();
    let output = cli.run(&["note", "evil \u{1b}[31mred\u{1b}[0m \u{202e}txt"]);
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!stdout.contains('\u{1b}') && !stdout.contains('\u{202e}'), "{stdout:?}");
    let (_, list) = cli.json(&["list", "--json"]);
    assert_eq!(list["items"][0]["text"], "evil \u{1b}[31mred\u{1b}[0m \u{202e}txt", "stored and JSON are lossless");
}

#[test]
fn version_json_reports_compatibility() {
    let cli = Cli::new();
    let (code, doc) = cli.json(&["--version", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["database_schema_version"], 2);
    assert_eq!(doc["json_contract_version"], 1);
}

#[test]
fn hide_never_launches_and_status_reports_it() {
    let cli = Cli::new();
    let (code, doc) = cli.json(&["status", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["app"]["running"], false);
    assert_eq!(doc["pet"]["visibility"], "hidden");
}

fn uuid_like(id: &str) {
    assert_eq!(id.len(), 36);
    assert_eq!(id.matches('-').count(), 4);
}
