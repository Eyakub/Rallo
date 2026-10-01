//! Process-level tests for `rallo agent-event` and `rallo agents` (0007),
//! against a temporary `$HOME` and data directory -- the real ones are never
//! touched. Uses a fake installed `Rallo.app` (a copy of the real built CLI
//! at `Contents/Helpers/rallo`), the same pattern as `terminal_setup.rs`/
//! `update.rs`, since `agent-event`'s ancestry walk skips Rallo's own bundle
//! and expects to find a real (or, here, fake) `.app` further up.

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use serde_json::Value;

struct Setup {
    _root: tempfile::TempDir,
    home: PathBuf,
    data_dir: PathBuf,
    cli: PathBuf,
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

impl Setup {
    /// `<root>/Home With Spaces/Applications/Rallo.app`, matching the layout
    /// an installed copy has, with the data directory kept outside `$HOME`
    /// (like the other CLI test suites' `RALLO_DATA_DIR`).
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let root_path = root.path().canonicalize().unwrap();
        let home = root_path.join("Home With Spaces");
        let app = home.join("Applications/Rallo.app");
        let cli = install_cli(&app);
        let data_dir = root_path.join("data");
        Self { _root: root, home, data_dir, cli }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(&self.cli);
        command
            .args(args)
            .env("HOME", &self.home)
            .env("RALLO_DATA_DIR", &self.data_dir)
            .env_remove("RALLO_APP_PATH")
            .env_remove("CODEX_HOME");
        command
    }

    fn db_path(&self) -> PathBuf {
        self.data_dir.join("rallo.sqlite3")
    }

    /// Runs `agent-event --agent <agent>` with `payload` piped to stdin.
    fn agent_event(&self, agent: &str, payload: &[u8]) -> Output {
        let mut child = self
            .command(&["agent-event", "--agent", agent])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(payload).unwrap();
        child.wait_with_output().unwrap()
    }

    fn json(&self, args: &[&str]) -> (i32, Value) {
        let output = self.command(args).stdin(Stdio::null()).output().unwrap();
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
        (output.status.code().unwrap(), serde_json::from_str(&stdout).unwrap())
    }
}

fn sessions(doc: &Value) -> &Vec<Value> {
    doc["sessions"].as_array().unwrap()
}

const CODEX_USER_PROMPT_SUBMIT: &str = r#"{"session_id":"01a0f386-3249-7ea0-b536-ac0ef629e13f","turn_id":"t1","transcript_path":null,"cwd":"/tmp/w","hook_event_name":"UserPromptSubmit","model":"m","permission_mode":"bypassPermissions","prompt":"secret prompt text"}"#;
const CODEX_STOP: &str = r#"{"session_id":"01a0f386-3249-7ea0-b536-ac0ef629e13f","turn_id":"t1","transcript_path":null,"cwd":"/tmp/w","hook_event_name":"Stop","model":"m","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"Hi there"}"#;
const CODEX_PERMISSION_REQUEST: &str = r#"{"session_id":"01a0f386-3249-7ea0-b536-ac0ef629e13f","turn_id":"t1","transcript_path":null,"cwd":"/tmp/w","hook_event_name":"PermissionRequest","model":"m","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"ls"}}"#;
const CODEX_SESSION_END: &str = r#"{"session_id":"01a0f386-3249-7ea0-b536-ac0ef629e13f","transcript_path":null,"cwd":"/tmp/w","hook_event_name":"SessionEnd","reason":"other"}"#;
const CLAUDE_NOTIFICATION_PERMISSION_PROMPT: &str = r#"{"session_id":"s1","cwd":"/tmp/w","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#;
const CLAUDE_PERMISSION_REQUEST_BASH: &str =
    r#"{"session_id":"s2","cwd":"/tmp/w","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#;

#[test]
fn every_agent_event_call_exits_zero_and_writes_nothing_to_stdout() {
    let setup = Setup::new();
    for payload in [
        CODEX_USER_PROMPT_SUBMIT.as_bytes(),
        CODEX_STOP.as_bytes(),
        CODEX_SESSION_END.as_bytes(),
        CLAUDE_NOTIFICATION_PERMISSION_PROMPT.as_bytes(),
        CLAUDE_PERMISSION_REQUEST_BASH.as_bytes(),
        b"not json at all",
        b"",
        b"{\"hook_event_name\":\"Stop\"}", // missing session_id
        b"[]",                             // valid JSON, not an object
    ] {
        let agent = if payload.starts_with(b"{\"session_id\":\"01a0f386") { "codex" } else { "claude" };
        let output = setup.agent_event(agent, payload);
        assert!(output.status.success(), "{output:?}");
        assert!(output.stdout.is_empty(), "stdout must always be empty: {output:?}");
    }
}

#[test]
fn codex_waiting_shows_and_stop_clears_it() {
    let setup = Setup::new();
    setup.agent_event("codex", CODEX_USER_PROMPT_SUBMIT.as_bytes());
    // `Working` is never pet-visible: not listed.
    let (_, doc) = setup.json(&["agents", "--json"]);
    assert!(sessions(&doc).is_empty(), "{doc}");

    setup.agent_event("codex", CODEX_PERMISSION_REQUEST.as_bytes());
    let (_, doc) = setup.json(&["agents", "--json"]);
    let list = sessions(&doc);
    assert_eq!(list.len(), 1, "{doc}");
    assert_eq!(list[0]["agent"], "codex");
    assert_eq!(list[0]["state"], "waiting");
    assert_eq!(list[0]["cwd"], "/tmp/w");

    // A finished turn isn't a question: Stop removes the row, as SessionEnd does.
    setup.agent_event("codex", CODEX_STOP.as_bytes());
    let (_, doc) = setup.json(&["agents", "--json"]);
    assert!(sessions(&doc).is_empty(), "Stop deletes the row: {doc}");
    let rows: i64 = rusqlite::Connection::open(setup.db_path())
        .unwrap()
        .query_row("SELECT COUNT(*) FROM agent_sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(rows, 0, "no finished row is kept behind the listing either");

    setup.agent_event("codex", CODEX_PERMISSION_REQUEST.as_bytes());
    setup.agent_event("codex", CODEX_SESSION_END.as_bytes());
    let (_, doc) = setup.json(&["agents", "--json"]);
    assert!(sessions(&doc).is_empty(), "SessionEnd deletes the row: {doc}");
}

#[test]
fn prompt_and_assistant_text_never_reach_the_database_file() {
    let setup = Setup::new();
    setup.agent_event("codex", CODEX_USER_PROMPT_SUBMIT.as_bytes());
    setup.agent_event("codex", CODEX_STOP.as_bytes());
    // Force a WAL checkpoint by reopening the CLI (`status` opens the store).
    setup.command(&["status", "--json"]).output().unwrap();

    let bytes = fs::read(setup.db_path()).unwrap();
    let contains = |needle: &str| bytes.windows(needle.len()).any(|window| window == needle.as_bytes());
    assert!(!contains("secret prompt text"), "the prompt must never be stored");
    assert!(!contains("Hi there"), "the assistant message must never be stored");
}

#[test]
fn claude_notification_and_permission_request_both_show_waiting() {
    let setup = Setup::new();
    setup.agent_event("claude", CLAUDE_NOTIFICATION_PERMISSION_PROMPT.as_bytes());
    setup.agent_event("claude", CLAUDE_PERMISSION_REQUEST_BASH.as_bytes());

    let (_, doc) = setup.json(&["agents", "--json"]);
    let list = sessions(&doc);
    assert_eq!(list.len(), 2, "{doc}");
    let s1 = list.iter().find(|s| s["session_id"] == "s1").unwrap();
    assert_eq!(s1["state"], "waiting");
    assert!(s1["detail"].is_null(), "a Notification waiting event carries no tool name: {s1}");
    let s2 = list.iter().find(|s| s["session_id"] == "s2").unwrap();
    assert_eq!(s2["state"], "waiting");
    assert_eq!(s2["detail"], "Bash");
}

#[test]
fn agents_clear_removes_and_reports_the_count() {
    let setup = Setup::new();
    setup.agent_event("claude", CLAUDE_PERMISSION_REQUEST_BASH.as_bytes());
    assert_eq!(setup.json(&["agents", "--json"]).1["sessions"].as_array().unwrap().len(), 1);

    let (code, doc) = setup.json(&["agents", "clear", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["cleared"], 1);
    assert!(sessions(&setup.json(&["agents", "--json"]).1).is_empty());

    let (_, doc) = setup.json(&["agents", "clear", "--json"]);
    assert_eq!(doc["cleared"], 0);
}
