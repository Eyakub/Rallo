//! Process-level tests for `rallo setup hooks` (0007), against a temporary
//! `$HOME`/`$CODEX_HOME` and a fake installed `Rallo.app` (a copy of the
//! real built CLI at `Contents/Helpers/rallo`, the same pattern as
//! `terminal_setup.rs`/`update.rs`), since the hook command string needs a
//! real installed CLI path. The real `~/.claude` and `~/.codex` are never
//! touched.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

struct Setup {
    _root: tempfile::TempDir,
    home: PathBuf,
    app: PathBuf,
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
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let root_path = root.path().canonicalize().unwrap();
        let home = root_path.join("Home With Spaces");
        let app = home.join("Applications/Rallo.app");
        let cli = install_cli(&app);
        Self { _root: root, home, app, cli }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(&self.cli);
        command
            .args(args)
            .env("HOME", &self.home)
            .env_remove("RALLO_APP_PATH")
            .env_remove("RALLO_DATA_DIR")
            .env_remove("CODEX_HOME")
            .env_remove("GROK_HOME")
            .env_remove("GEMINI_CLI_HOME");
        command
    }

    fn claude_settings(&self) -> PathBuf {
        self.home.join(".claude/settings.json")
    }

    fn codex_hooks(&self, codex_home: &Path) -> PathBuf {
        codex_home.join("hooks.json")
    }

    fn json(&self, args: &[&str]) -> (i32, Value) {
        let output = self.command(args).output().unwrap();
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
        (output.status.code().unwrap(), serde_json::from_str(&stdout).unwrap())
    }
}

fn install<'a>(doc: &'a Value, agent: &str) -> &'a Value {
    doc["hooks"]["targets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|target| target["agent"] == agent)
        .unwrap_or_else(|| panic!("no {agent} target in {doc}"))
}

fn rallo_group_commands(events: &Value, event: &str) -> Vec<String> {
    events["hooks"][event]
        .as_array()
        .map(|groups| {
            groups
                .iter()
                .flat_map(|group| group["hooks"].as_array().unwrap())
                .map(|hook| hook["command"].as_str().unwrap().to_owned())
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn install_merges_creates_the_expected_events_and_is_idempotent() {
    let setup = Setup::new();
    fs::create_dir_all(setup.home.join(".claude")).unwrap();

    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "claude", "--json"]);
    assert_eq!(code, 0, "{doc}");
    let claude = install(&doc, "claude");
    assert_eq!(claude["status"], "installed");
    assert!(claude["backup_path"].is_null(), "no backup when the file did not exist before");

    let content: Value = serde_json::from_str(&fs::read_to_string(setup.claude_settings()).unwrap()).unwrap();
    let expected_command =
        format!("\"{}\" agent-event --agent claude || true", setup.app.join("Contents/Helpers/rallo").display());
    for event in ["PermissionRequest", "Notification", "PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd"] {
        let commands = rallo_group_commands(&content, event);
        assert_eq!(commands, vec![expected_command.clone()], "event {event}: {content}");
    }
    // No matcher key: the group fires for every tool.
    assert!(content["hooks"]["PermissionRequest"][0].get("matcher").is_none());

    let first_write = fs::read_to_string(setup.claude_settings()).unwrap();
    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "claude", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "claude")["status"], "already_installed");
    assert_eq!(fs::read_to_string(setup.claude_settings()).unwrap(), first_write, "a no-op install writes nothing");
}

#[test]
fn foreign_hooks_and_key_order_survive_install_with_exactly_one_backup() {
    let setup = Setup::new();
    fs::create_dir_all(setup.home.join(".claude")).unwrap();
    let original = "{\n  \"zzz_first\": 1,\n  \"hooks\": {\n    \"UserPromptSubmit\": [\n      {\"matcher\": \"\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo hi\", \"timeout\": 5}]}\n    ]\n  },\n  \"aaa_last\": 2\n}\n";
    fs::write(setup.claude_settings(), original).unwrap();

    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "claude", "--json"]);
    assert_eq!(code, 0, "{doc}");
    // "installed", not "updated": no Rallo entry existed before, even though
    // the file itself (with unrelated content) did.
    assert_eq!(install(&doc, "claude")["status"], "installed");
    let backup_path = install(&doc, "claude")["backup_path"].as_str().unwrap().to_owned();
    assert_eq!(fs::read_to_string(&backup_path).unwrap(), original, "the pristine pre-Rallo file is preserved");

    let written = fs::read_to_string(setup.claude_settings()).unwrap();
    assert!(
        written.find("zzz_first").unwrap() < written.find("\"hooks\"").unwrap()
            && written.find("\"hooks\"").unwrap() < written.find("aaa_last").unwrap(),
        "untouched top-level keys keep their original order: {written}"
    );
    let content: Value = serde_json::from_str(&written).unwrap();
    let user_prompt_groups = content["hooks"]["UserPromptSubmit"].as_array().unwrap();
    assert_eq!(user_prompt_groups.len(), 2, "the foreign group plus Rallo's own: {content}");
    assert_eq!(user_prompt_groups[0]["hooks"][0]["command"], "echo hi", "the foreign hook is untouched");

    // A second run must not overwrite the one true backup.
    setup.json(&["setup", "hooks", "--agent", "claude", "--json"]);
    assert_eq!(fs::read_to_string(&backup_path).unwrap(), original);
}

#[test]
fn a_stale_rallo_entry_from_a_moved_app_is_replaced_and_reports_updated() {
    let setup = Setup::new();
    fs::create_dir_all(setup.home.join(".claude")).unwrap();
    let stale = "{\"hooks\": {\"PermissionRequest\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"\\\"/Volumes/Old/Rallo.app/Contents/Helpers/rallo\\\" agent-event --agent claude\", \"timeout\": 10}]}]}}\n";
    fs::write(setup.claude_settings(), stale).unwrap();

    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "claude", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "claude")["status"], "updated");

    let content: Value = serde_json::from_str(&fs::read_to_string(setup.claude_settings()).unwrap()).unwrap();
    let commands = rallo_group_commands(&content, "PermissionRequest");
    assert_eq!(commands.len(), 1, "the stale entry was replaced, not just appended alongside: {content}");
    assert!(commands[0].contains(&setup.app.display().to_string()), "{commands:?}");
}

#[test]
fn remove_only_removes_rallos_own_entries() {
    let setup = Setup::new();
    fs::create_dir_all(setup.home.join(".claude")).unwrap();
    let foreign = "{\"hooks\": {\"UserPromptSubmit\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo hi\", \"timeout\": 5}]}]}}\n";
    fs::write(setup.claude_settings(), foreign).unwrap();

    setup.json(&["setup", "hooks", "--agent", "claude", "--json"]);
    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "claude", "--remove", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "claude")["status"], "removed");

    let content: Value = serde_json::from_str(&fs::read_to_string(setup.claude_settings()).unwrap()).unwrap();
    assert!(content["hooks"]["PermissionRequest"].is_null(), "Rallo's events are gone: {content}");
    let user_prompt_groups = content["hooks"]["UserPromptSubmit"].as_array().unwrap();
    assert_eq!(user_prompt_groups.len(), 1, "the foreign group survives: {content}");
    assert_eq!(user_prompt_groups[0]["hooks"][0]["command"], "echo hi");

    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "claude", "--remove", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "claude")["status"], "not_present");
}

#[test]
fn invalid_json_is_refused_and_writes_nothing_for_any_target() {
    let setup = Setup::new();
    fs::create_dir_all(setup.home.join(".claude")).unwrap();
    let codex_home = setup.home.join(".codex");
    fs::create_dir_all(&codex_home).unwrap();

    // A valid Claude file alongside an invalid Codex one: nothing should be
    // written to Claude's file even though only Codex's is broken.
    let valid_claude = "{}\n";
    fs::write(setup.claude_settings(), valid_claude).unwrap();
    fs::write(setup.codex_hooks(&codex_home), "{ not json").unwrap();

    let output = setup
        .command(&["setup", "hooks", "--agent", "claude", "--agent", "codex", "--json"])
        .env("CODEX_HOME", &codex_home)
        .output()
        .unwrap();
    let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(output.status.code(), Some(4), "{doc}");
    assert_eq!(doc["error"]["code"], "HOOKS_CONFIG_INVALID");
    assert!(doc["error"]["message"].as_str().unwrap().contains("hooks.json"), "{doc}");
    assert_eq!(fs::read_to_string(setup.claude_settings()).unwrap(), valid_claude, "nothing written for any target");
}

#[test]
fn print_shows_groups_and_writes_nothing() {
    let setup = Setup::new();
    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "claude", "--print", "--json"]);
    assert_eq!(code, 0, "{doc}");
    let groups = doc["hooks"]["groups"].as_array().unwrap();
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0]["agent"], "claude");
    assert!(groups[0]["events"]["PermissionRequest"]["hooks"].is_array());
    assert!(!setup.claude_settings().exists(), "print never writes");
}

#[test]
fn codex_home_env_var_selects_the_hooks_json_location() {
    let setup = Setup::new();
    let codex_home = tempfile::tempdir().unwrap();

    let (code, doc) = setup
        .command(&["setup", "hooks", "--agent", "codex", "--json"])
        .env("CODEX_HOME", codex_home.path())
        .output()
        .map(|output| {
            let stdout = String::from_utf8(output.stdout).unwrap();
            (output.status.code().unwrap(), serde_json::from_str::<Value>(&stdout).unwrap())
        })
        .unwrap();
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "codex")["path"], codex_home.path().join("hooks.json").to_str().unwrap());
    assert!(codex_home.path().join("hooks.json").is_file());
}

#[test]
fn grok_hooks_install_into_a_rallo_owned_file_and_remove_cleanly() {
    let setup = Setup::new();
    let grok_home = setup.home.join(".grok");
    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "grok", "--json"]);
    assert_eq!(code, 0, "{doc}");
    let path = grok_home.join("hooks/rallo.json");
    assert_eq!(install(&doc, "grok")["path"], path.to_str().unwrap());
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("agent-event --agent grok || true") && text.contains("StopCancelled"), "{text}");

    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "grok", "--remove", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "grok")["status"], "removed");
    assert!(!path.exists(), "an emptied Rallo-owned file is deleted");
    let left: Vec<_> = fs::read_dir(grok_home.join("hooks")).unwrap().collect();
    assert!(left.is_empty(), "no backup of Rallo's own file: {left:?}");
}

#[test]
fn gemini_hooks_merge_into_settings_with_millisecond_timeouts() {
    let setup = Setup::new();
    let path = setup.home.join(".gemini/settings.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, r#"{"theme":"dark","hooks":{"SessionStart":[]},"zeta":1}"#).unwrap();
    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "gemini", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "gemini")["path"], path.to_str().unwrap());
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("agent-event --agent gemini || true") && text.contains("\"AfterAgent\""), "{text}");
    assert!(text.contains("\"timeout\": 10000") && !text.contains("\"timeout\": 10,"), "{text}");
    assert!(text.find("theme").unwrap() < text.find("hooks").unwrap(), "foreign key order kept: {text}");
    assert!(text.find("hooks").unwrap() < text.find("zeta").unwrap(), "foreign key order kept: {text}");

    let (code, doc) = setup.json(&["setup", "hooks", "--agent", "gemini", "--remove", "--json"]);
    assert_eq!(code, 0, "{doc}");
    let left: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(left, serde_json::json!({"theme":"dark","hooks":{"SessionStart":[]},"zeta":1}));
}

#[test]
fn rewriting_settings_keeps_their_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let setup = Setup::new();
    fs::create_dir_all(setup.claude_settings().parent().unwrap()).unwrap();
    fs::write(setup.claude_settings(), "{\"env\": {\"SECRET\": \"x\"}}\n").unwrap();
    fs::set_permissions(setup.claude_settings(), fs::Permissions::from_mode(0o600)).unwrap();
    let (code, _) = setup.json(&["setup", "hooks", "--agent", "claude", "--json"]);
    assert_eq!(code, 0);
    let mode = fs::metadata(setup.claude_settings()).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "settings.json must stay private");
}

/// Gemini CLI allows comments in settings.json; Rallo's strict parser can't edit such a file.
fn commented_gemini_and_valid_claude(setup: &Setup) -> (PathBuf, &'static str) {
    fs::create_dir_all(setup.home.join(".claude")).unwrap();
    fs::write(setup.claude_settings(), "{}\n").unwrap();
    let gemini = setup.home.join(".gemini/settings.json");
    fs::create_dir_all(gemini.parent().unwrap()).unwrap();
    let commented = "{\n  // keep me\n  \"theme\": \"dark\"\n}\n";
    fs::write(&gemini, commented).unwrap();
    (gemini, commented)
}

#[test]
fn an_unreadable_detected_file_is_skipped_with_a_warning_by_default() {
    let setup = Setup::new();
    let (gemini, commented) = commented_gemini_and_valid_claude(&setup);

    let (code, doc) = setup.json(&["setup", "hooks", "--json"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "claude")["status"], "installed");
    assert_eq!(doc["hooks"]["targets"].as_array().unwrap().len(), 1, "{doc}");
    let warnings = doc["warnings"].as_array().unwrap();
    assert!(
        warnings.iter().any(|w| {
            let w = w.as_str().unwrap();
            w.contains("settings.json") && w.contains("comments")
        }),
        "{doc}"
    );
    assert_eq!(fs::read_to_string(&gemini).unwrap(), commented, "Gemini file untouched");
}

#[test]
fn an_unreadable_file_named_with_agent_is_still_refused() {
    let setup = Setup::new();
    let (gemini, commented) = commented_gemini_and_valid_claude(&setup);

    let output = setup.command(&["setup", "hooks", "--agent", "gemini", "--json"]).output().unwrap();
    let doc: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(output.status.code(), Some(4), "{doc}");
    assert_eq!(doc["error"]["code"], "HOOKS_CONFIG_INVALID");
    assert_eq!(fs::read_to_string(&gemini).unwrap(), commented);
    assert_eq!(fs::read_to_string(setup.claude_settings()).unwrap(), "{}\n");
}
