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

// --- M1 part C: full command surface -----------------------------------

#[test]
fn every_command_emits_one_valid_json_document_with_no_ansi() {
    let cli = Cli::new();

    let (code, note) = cli.json(&["note", "plain note", "--json"]);
    assert_eq!(code, 0);
    let note_id = note["item"]["id"].as_str().unwrap().to_owned();

    let (code, remind) = cli.json(&["remind", "reminder note", "--in", "20m", "--json"]);
    assert_eq!(code, 0);
    let remind_id = remind["item"]["id"].as_str().unwrap().to_owned();

    assert_eq!(cli.json(&["list", "--json"]).0, 0);
    assert_eq!(cli.json(&["list", "--all", "--json"]).0, 0);
    assert_eq!(cli.json(&["list", "--deleted", "--json"]).0, 0);
    assert_eq!(cli.json(&["list", "--due", "--json"]).0, 0);
    assert_eq!(cli.json(&["get", &note_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["search", "note", "--json"]).0, 0);
    assert_eq!(cli.json(&["search", "plain note", "--exact", "--json"]).0, 0);
    assert_eq!(cli.json(&["edit", &note_id, "--text", "plain note v2", "--json"]).0, 0);
    assert_eq!(cli.json(&["done", &note_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["reopen", &note_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["reschedule", &remind_id, "--in", "30m", "--json"]).0, 0);
    assert_eq!(cli.json(&["snooze", &remind_id, "--in", "10m", "--json"]).0, 0);
    assert_eq!(cli.json(&["acknowledge", &remind_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["cancel-reminder", &remind_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["delete", &note_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["restore", &note_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["status", "--json"]).0, 0);
    assert_eq!(cli.json(&["status", &note_id, "--json"]).0, 0);
    assert_eq!(cli.json(&["--version", "--json"]).0, 0);

    // A couple of guaranteed-failure shapes must still be one clean document.
    assert_eq!(cli.json(&["delete", "--text", "does-not-exist", "--json"]).0, 3);
    assert_eq!(cli.json(&["remind", "bad", "--in", "0m", "--json"]).0, 2);
}

#[test]
fn missing_app_becomes_a_warning_not_a_failure() {
    let cli = Cli::new();
    // `remind` always nudges the app (build plan §5), unlike a plain note
    // while hidden; RALLO_APP_PATH is unset, so the launch must fail
    // harmlessly into a warning, not a nonzero exit.
    let (code, doc) = cli.json(&["remind", "warn me", "--in", "5m", "--json"]);
    assert_eq!(code, 0);
    let warnings = doc["warnings"].as_array().unwrap();
    assert!(warnings.iter().any(|w| w.as_str().unwrap().contains("not started")), "{warnings:?}");
}

#[test]
fn human_remind_output_says_scheduling_pending_never_reminder_set() {
    let cli = Cli::new();
    let output = cli.run(&["remind", "check wording", "--in", "5m"]);
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(stdout.contains("scheduling pending"), "{stdout:?}");
    assert!(!stdout.to_lowercase().contains("reminder set"), "{stdout:?}");
}

#[test]
fn remind_accepts_stdin_text() {
    let cli = Cli::new();
    let output = cli.run_stdin(&["remind", "--stdin", "--in", "5m", "--json"], b"stdin reminder\n");
    assert!(output.status.success());
    assert_eq!(parse(&output)["item"]["text"], "stdin reminder");
}

#[test]
fn remind_zero_duration_is_invalid_exit_2() {
    let cli = Cli::new();
    let (code, doc) = cli.json(&["remind", "zero", "--in", "0m", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(doc["error"]["code"], "INVALID_TIME");
}

#[test]
fn remind_requires_exactly_one_of_in_or_at() {
    let cli = Cli::new();
    assert_eq!(cli.run(&["remind", "x"]).status.code(), Some(2), "neither given");
    assert_eq!(
        cli.run(&["remind", "x", "--in", "5m", "--at", "2030-01-01T00:00:00Z"]).status.code(),
        Some(2),
        "both given"
    );
}

#[test]
fn delete_requires_exactly_one_selector() {
    let cli = Cli::new();
    assert_eq!(cli.run(&["delete"]).status.code(), Some(2), "neither given");
    let (_, note) = cli.json(&["note", "x", "--json"]);
    let id = note["item"]["id"].as_str().unwrap();
    assert_eq!(cli.run(&["delete", id, "--text", "x"]).status.code(), Some(2), "both given");
}

#[test]
fn delete_if_revision_is_rejected_alongside_text_selector() {
    let cli = Cli::new();
    assert_eq!(cli.run(&["delete", "--text", "x", "--if-revision", "1"]).status.code(), Some(2));
}

#[test]
fn list_conflicting_filters_are_rejected_exit_2() {
    let cli = Cli::new();
    assert_eq!(cli.run(&["list", "--all", "--deleted"]).status.code(), Some(2));
    assert_eq!(cli.run(&["list", "--all", "--due"]).status.code(), Some(2));
    assert_eq!(cli.run(&["list", "--deleted", "--due"]).status.code(), Some(2));
}

#[test]
fn not_found_by_id_is_exit_3() {
    let cli = Cli::new();
    let (code, doc) = cli.json(&["get", "00000000-0000-0000-0000-000000000000", "--json"]);
    assert_eq!(code, 3);
    assert_eq!(doc["error"]["code"], "ITEM_NOT_FOUND");
}

#[test]
fn reminder_capacity_reports_detail_on_the_33rd_active_reminder() {
    let cli = Cli::new();
    for i in 0..32 {
        let (code, _) = cli.json(&["remind", &format!("cap {i}"), "--in", "1h", "--json"]);
        assert_eq!(code, 0);
    }
    let (code, doc) = cli.json(&["remind", "cap 33", "--in", "1h", "--json"]);
    assert_eq!(code, 4);
    assert_eq!(doc["error"]["code"], "REMINDER_CAPACITY_REACHED");
    assert_eq!(doc["error"]["detail"]["limit"], 32);
    assert_eq!(doc["error"]["detail"]["active"], 32);
}

#[test]
fn stale_if_revision_reports_current_snapshot_and_mutates_nothing() {
    let cli = Cli::new();
    let (_, note) = cli.json(&["note", "stale target", "--json"]);
    let id = note["item"]["id"].as_str().unwrap();

    let (code, doc) = cli.json(&["edit", id, "--text", "new text", "--if-revision", "999", "--json"]);
    assert_eq!(code, 4);
    assert_eq!(doc["error"]["code"], "REVISION_CONFLICT");
    assert_eq!(doc["error"]["detail"]["current"]["text"], "stale target");
    assert_eq!(doc["error"]["detail"]["current"]["revision"], 1);

    let (_, current) = cli.json(&["get", id, "--json"]);
    assert_eq!(current["item"]["text"], "stale target", "nothing changed");
    assert_eq!(current["item"]["revision"], 1);
}

#[test]
fn retried_snooze_request_id_does_not_move_the_deadline() {
    let cli = Cli::new();
    let (_, remind) = cli.json(&["remind", "snooze me", "--in", "20m", "--json"]);
    let id = remind["item"]["id"].as_str().unwrap();

    let (_, first) = cli.json(&["snooze", id, "--in", "5m", "--request-id", "snz-1", "--json"]);
    let deadline = first["item"]["reminder"]["deadline_ms"].as_i64().unwrap();

    std::thread::sleep(std::time::Duration::from_millis(1100));
    let (code, second) = cli.json(&["snooze", id, "--in", "5m", "--request-id", "snz-1", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(second["replayed"], true);
    assert_eq!(second["item"]["reminder"]["deadline_ms"].as_i64().unwrap(), deadline);
}

#[test]
fn delete_by_text_zero_one_many_matches() {
    let cli = Cli::new();

    let (code, doc) = cli.json(&["delete", "--text", "nope", "--json"]);
    assert_eq!(code, 3);
    assert_eq!(doc["error"]["code"], "ITEM_NOT_FOUND");

    cli.run(&["note", "solo text"]);
    let (code, doc) = cli.json(&["delete", "--text", "solo text", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["changed"], true);

    cli.run(&["note", "dup text"]);
    cli.run(&["note", "dup text"]);
    let (code, doc) = cli.json(&["delete", "--text", "dup text", "--json"]);
    assert_eq!(code, 4);
    assert_eq!(doc["error"]["code"], "AMBIGUOUS_ITEM");
    assert_eq!(doc["error"]["detail"]["total"], 2);
    assert_eq!(doc["error"]["detail"]["candidates"].as_array().unwrap().len(), 2);

    let (_, list) = cli.json(&["list", "--all", "--json"]);
    let remaining = list["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["text"] == "dup text" && item["deleted_at_ms"].is_null())
        .count();
    assert_eq!(remaining, 2, "nothing was deleted by the ambiguous attempt");

    let output = cli.run(&["delete", "--text", "dup text"]);
    assert_eq!(output.status.code(), Some(4));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("dup text"), "{stderr:?}");
    assert!(stderr.lines().count() >= 3, "message plus one line per candidate: {stderr:?}");
}

#[test]
fn golden_path_7_search_exact_delete_undo_restore_without_reviving_reminder() {
    let cli = Cli::new();
    cli.run(&["remind", "Review deployment", "--in", "20m"]);

    let (_, search) = cli.json(&["search", "Review deployment", "--exact", "--json"]);
    assert_eq!(search["total_count"], 1, "an agent may only claim uniqueness from this count");
    let item = &search["items"][0];
    let id = item["id"].as_str().unwrap().to_owned();
    let revision = item["revision"].as_i64().unwrap();

    let (code, deleted) =
        cli.json(&["delete", &id, "--if-revision", &revision.to_string(), "--request-id", "del-review", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(deleted["changed"], true);
    assert_eq!(deleted["undo"]["item_id"], id);
    let display_id = deleted["undo"]["command"].as_str().unwrap().rsplit(' ').next().unwrap().to_owned();

    let (code, restored) = cli.json(&["restore", &display_id, "--json"]);
    assert_eq!(code, 0);
    assert!(restored["item"]["deleted_at_ms"].is_null());
    assert_eq!(restored["item"]["text"], "Review deployment");
    assert_eq!(restored["item"]["reminder"]["state"], "deleted", "restore never re-enables the old reminder");
}

#[test]
fn golden_path_8_ambiguous_candidates_then_unique_delete_then_replay_skips_new_same_text_item() {
    let cli = Cli::new();
    cli.run(&["note", "twin"]);
    cli.run(&["note", "twin"]);

    let (code, doc) = cli.json(&["delete", "--text", "twin", "--json"]);
    assert_eq!(code, 4);
    assert_eq!(doc["error"]["code"], "AMBIGUOUS_ITEM");

    let (_, list) = cli.json(&["list", "--json"]);
    let ids: Vec<String> =
        list["items"].as_array().unwrap().iter().map(|item| item["id"].as_str().unwrap().to_owned()).collect();
    assert_eq!(ids.len(), 2, "nothing deleted by the ambiguous attempt");

    let chosen = &ids[0];
    let (code, doc) = cli.json(&["delete", chosen, "--request-id", "del-twin", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["changed"], true);

    let (_, list) = cli.json(&["list", "--json"]);
    assert_eq!(list["items"].as_array().unwrap().len(), 1, "only the chosen item was deleted");

    // A new same-text note must not be caught by the retried request id.
    cli.run(&["note", "twin"]);
    let (code, doc) = cli.json(&["delete", chosen, "--request-id", "del-twin", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["replayed"], true);
    assert_eq!(doc["item"]["id"], *chosen);

    let (_, list) = cli.json(&["list", "--json"]);
    assert_eq!(list["items"].as_array().unwrap().len(), 2, "no second deletion occurred");
}

#[test]
fn pagination_walks_every_item_via_next_cursor_with_a_stable_total_count() {
    let cli = Cli::new();
    for i in 0..5 {
        cli.run(&["note", &format!("item {i}")]);
    }

    let mut seen = std::collections::HashSet::new();
    let mut cursor: Option<String> = None;
    let mut total_count = None;
    loop {
        let mut args = vec!["list", "--limit", "2", "--json"];
        if let Some(cursor) = &cursor {
            args.push("--cursor");
            args.push(cursor);
        }
        let (code, page) = cli.json(&args);
        assert_eq!(code, 0);
        assert!(page["items"].as_array().unwrap().len() <= 2);

        let this_total = page["total_count"].as_u64().unwrap();
        match total_count {
            None => total_count = Some(this_total),
            Some(expected) => assert_eq!(this_total, expected, "total_count must not depend on the page size"),
        }
        for item in page["items"].as_array().unwrap() {
            seen.insert(item["id"].as_str().unwrap().to_owned());
        }
        cursor = page["next_cursor"].as_str().map(str::to_owned);
        if cursor.is_none() {
            break;
        }
    }
    assert_eq!(seen.len(), 5);
    assert_eq!(total_count, Some(5));
}

// --- export/import (0004) -------------------------------------------------

#[test]
fn export_to_file_then_import_into_a_fresh_data_dir_round_trips() {
    let source = Cli::new();
    let (_, note) = source.json(&["note", "exported note", "--json"]);
    let id = note["item"]["id"].as_str().unwrap().to_owned();

    let out_dir = tempfile::tempdir().unwrap();
    let export_path = out_dir.path().join("backup.json");
    let (code, doc) = source.json(&["export", "--output", export_path.to_str().unwrap(), "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["export"]["items"], 1);
    assert_eq!(doc["export"]["format"], "json");
    assert!(export_path.exists());

    let target = Cli::new();
    let (code, doc) = target.json(&["import", "--file", export_path.to_str().unwrap(), "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["new"], 1);
    assert_eq!(doc["applied"], true);
    assert!(doc["backup_path"].is_string());

    let (_, got) = target.json(&["get", &id, "--json"]);
    assert_eq!(got["item"]["text"], "exported note");
}

#[test]
fn export_output_dash_writes_raw_bytes_to_stdout() {
    let cli = Cli::new();
    cli.run(&["note", "to stdout"]);
    let output = cli.run(&["export", "--output", "-"]);
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    let document: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(document["format"], "rallo.export");
    assert_eq!(document["items"][0]["text"], "to stdout");
}

#[test]
fn export_refuses_to_overwrite_without_force_but_force_replaces() {
    let cli = Cli::new();
    cli.run(&["note", "first"]);
    let out_dir = tempfile::tempdir().unwrap();
    let path = out_dir.path().join("export.json");
    assert!(cli.run(&["export", "--output", path.to_str().unwrap()]).status.success());

    let (code, doc) = cli.json(&["export", "--output", path.to_str().unwrap(), "--json"]);
    assert_eq!(code, 4, "FILE_EXISTS is a conflict, not a usage error");
    assert_eq!(doc["error"]["code"], "FILE_EXISTS");

    cli.run(&["note", "second"]);
    let (code, doc) = cli.json(&["export", "--output", path.to_str().unwrap(), "--force", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["export"]["items"], 2);
}

#[test]
fn export_format_defaults_from_the_output_extension() {
    let cli = Cli::new();
    cli.run(&["note", "csv please"]);
    let out_dir = tempfile::tempdir().unwrap();
    let path = out_dir.path().join("export.csv");
    let (code, doc) = cli.json(&["export", "--output", path.to_str().unwrap(), "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["export"]["format"], "csv");
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..3], [0xEF, 0xBB, 0xBF]);
}

#[test]
fn import_dry_run_reports_without_writing_anything() {
    let source = Cli::new();
    source.run(&["note", "dry run me"]);
    let out_dir = tempfile::tempdir().unwrap();
    let path = out_dir.path().join("export.json");
    source.run(&["export", "--output", path.to_str().unwrap()]);

    let target = Cli::new();
    let (code, doc) = target.json(&["import", "--file", path.to_str().unwrap(), "--dry-run", "--json"]);
    assert_eq!(code, 0);
    assert_eq!(doc["new"], 1);
    assert_eq!(doc["applied"], false);
    assert!(doc["backup_path"].is_null());

    let (_, list) = target.json(&["list", "--json"]);
    assert_eq!(list["items"], serde_json::json!([]), "dry run wrote nothing");
}

#[test]
fn import_conflict_exits_4_with_nothing_changed_and_stderr_detail() {
    let source = Cli::new();
    let (_, note) = source.json(&["note", "shared text", "--json"]);
    let out_dir = tempfile::tempdir().unwrap();
    let path = out_dir.path().join("export.json");
    source.run(&["export", "--output", path.to_str().unwrap()]);

    let target = Cli::new();
    assert!(target.run(&["import", "--file", path.to_str().unwrap()]).status.success());
    let (_, before) = target.json(&["get", note["item"]["id"].as_str().unwrap(), "--json"]);
    assert_eq!(before["item"]["revision"], 1);

    // Edit the source note so a re-export/re-import of the same id conflicts.
    source.run(&["edit", note["item"]["id"].as_str().unwrap(), "--text", "edited elsewhere"]);
    source.run(&["export", "--output", path.to_str().unwrap(), "--force"]);

    let output = target.run(&["import", "--file", path.to_str().unwrap()]);
    assert_eq!(output.status.code(), Some(4));
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("Nothing was imported"), "{stderr:?}");

    let (_, after) = target.json(&["get", note["item"]["id"].as_str().unwrap(), "--json"]);
    assert_eq!(after["item"]["text"], "shared text", "nothing changed on conflict");
}

#[test]
fn import_accepts_stdin_with_dash() {
    let source = Cli::new();
    source.run(&["note", "via stdin"]);
    let export = source.run(&["export", "--output", "-"]);
    assert!(export.status.success());

    let target = Cli::new();
    let output = target.run_stdin(&["import", "--file", "-", "--json"], &export.stdout);
    assert!(output.status.success());
    let doc = parse(&output);
    assert_eq!(doc["new"], 1);

    let (_, list) = target.json(&["list", "--json"]);
    assert_eq!(list["items"][0]["text"], "via stdin");
}

#[test]
fn unreadable_store_names_the_sandbox_case() {
    use std::os::unix::fs::PermissionsExt;
    let parent = tempfile::tempdir().unwrap();
    std::fs::set_permissions(parent.path(), std::fs::Permissions::from_mode(0o500)).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_rallo"))
        .args(["--json", "note", "x"])
        .env("RALLO_DATA_DIR", parent.path().join("data"))
        .env("RALLO_APP_PATH", "/nonexistent")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    std::fs::set_permissions(parent.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let doc = parse(&output);
    assert_eq!(doc["error"]["code"], "STORAGE_UNAVAILABLE");
    let message = doc["error"]["message"].as_str().unwrap();
    assert!(message.contains("sandbox") && message.contains("rallo setup skill"), "{message}");
}
