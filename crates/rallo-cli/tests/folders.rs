//! Folders and tags through the CLI (0019). Each test uses its own data directory.

use std::process::{Command, Output, Stdio};

use serde_json::{Value, json};

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

    fn json(&self, args: &[&str]) -> (i32, Value) {
        let mut all = args.to_vec();
        all.push("--json");
        let output = self.run(&all);
        (output.status.code().unwrap(), parse(&output))
    }

    /// Runs a command that must succeed and returns its JSON.
    fn ok(&self, args: &[&str]) -> Value {
        let (code, doc) = self.json(args);
        assert_eq!(code, 0, "{args:?} failed: {doc}");
        doc
    }

    fn texts(&self, args: &[&str]) -> Vec<String> {
        let doc = self.ok(args);
        doc["items"].as_array().unwrap().iter().map(|item| item["text"].as_str().unwrap().to_owned()).collect()
    }
}

fn parse(output: &Output) -> Value {
    let stdout = String::from_utf8(output.stdout.clone()).unwrap();
    assert!(!stdout.contains('\u{1b}'), "JSON stdout must not contain ANSI escapes");
    assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
    serde_json::from_str(&stdout).unwrap()
}

fn id_of(doc: &Value) -> String {
    doc["item"]["id"].as_str().unwrap().to_owned()
}

#[test]
fn note_and_remind_take_a_folder_and_an_unknown_one_saves_nothing() {
    let cli = Cli::new();
    let created = cli.ok(&["folder", "create", "Work"]);
    assert_eq!(created["folder"]["name"], "Work");
    assert_eq!(created["changed"], true);
    let work_id = created["folder"]["id"].clone();

    let note = cli.ok(&["note", "ship it #release", "--folder", "work"]);
    assert_eq!(note["item"]["folder"], json!({ "id": work_id, "name": "Work" }));
    assert_eq!(note["item"]["tags"], json!(["release"]));
    let remind = cli.ok(&["remind", "standup", "--in", "20m", "--folder", "WORK"]);
    assert_eq!(remind["item"]["folder"]["name"], "Work");
    let plain = cli.ok(&["note", "loose", "--folder", "Notes"]);
    assert!(plain["item"]["folder"].is_null());
    assert_eq!(plain["item"]["tags"], json!([]));

    let (code, doc) = cli.json(&["note", "typo", "--folder", "Wrok"]);
    assert_eq!(code, 3);
    assert_eq!(doc["error"]["code"], "FOLDER_NOT_FOUND");
    let message = doc["error"]["message"].as_str().unwrap();
    assert!(message.contains("Wrok") && message.contains("Work") && message.contains("Notes"), "{message}");
    let (code, doc) = cli.json(&["remind", "typo", "--in", "5m", "--folder", "Wrok"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (3, "FOLDER_NOT_FOUND"));
    assert_eq!(cli.ok(&["list", "--all"])["total_count"], 3, "neither typo saved a note");
    assert_eq!(cli.ok(&["folders"])["folders"].as_array().unwrap().len(), 2, "and no junk folder appeared");
}

#[test]
fn folders_and_tags_json_shapes() {
    let cli = Cli::new();
    cli.ok(&["folder", "create", "work"]);
    cli.ok(&["folder", "create", "Archive"]);
    cli.ok(&["note", "a #bug", "--folder", "work"]);
    cli.ok(&["note", "b #bug #ui"]);
    cli.ok(&["note", "c #ui", "--folder", "Archive"]);
    let done = id_of(&cli.ok(&["note", "d #finished", "--folder", "work"]));
    cli.ok(&["done", &done]);

    let folders = cli.ok(&["folders"]);
    assert_eq!(folders["schema_version"], 1);
    let list = folders["folders"].as_array().unwrap();
    assert_eq!(list[0], json!({ "id": null, "name": "Notes", "open_count": 1 }));
    assert_eq!(list[1]["name"], "Archive");
    assert_eq!(list[1]["open_count"], 1);
    assert_eq!(list[2]["name"], "work");
    assert_eq!(list[2]["open_count"], 1, "the done note doesn't count");
    assert!(list[2]["id"].is_string());

    let tags = cli.ok(&["tags"]);
    assert_eq!(tags["tags"], json!([{ "name": "bug", "open_count": 2 }, { "name": "ui", "open_count": 2 }]));
}

#[test]
fn list_and_search_filter_by_folder_tag_and_done() {
    let cli = Cli::new();
    cli.ok(&["folder", "create", "Work"]);
    cli.ok(&["note", "w1 #bug", "--folder", "Work"]);
    cli.ok(&["note", "n1 #bug"]);
    let w2 = id_of(&cli.ok(&["note", "w2 #bug", "--folder", "Work"]));
    cli.ok(&["done", &w2]);

    assert_eq!(cli.texts(&["list", "--folder", "work"]), ["w1 #bug"]);
    assert_eq!(cli.texts(&["list", "--folder", "Notes"]), ["n1 #bug"]);
    assert_eq!(cli.texts(&["list", "--tag", "#bug"]).len(), 2);
    assert_eq!(cli.texts(&["list", "--tag", "bug", "--folder", "Work", "--all"]).len(), 2);
    assert_eq!(cli.texts(&["list", "--done"]), ["w2 #bug"]);
    assert_eq!(cli.texts(&["list", "--done", "--folder", "Notes"]), Vec::<String>::new());
    assert_eq!(cli.ok(&["list", "--folder", "Work", "--all", "--limit", "1"])["total_count"], 2);
    assert_eq!(cli.texts(&["search", "bug", "--folder", "Notes"]), ["n1 #bug"]);
    assert_eq!(cli.ok(&["search", "bug"])["total_count"], 3);

    let (code, doc) = cli.json(&["list", "--tag", "123"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (2, "INVALID_INPUT"));
    let (code, doc) = cli.json(&["list", "--folder", "Nope"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (3, "FOLDER_NOT_FOUND"));
    let (code, doc) = cli.json(&["search", "x", "--folder", "Nope"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (3, "FOLDER_NOT_FOUND"));
}

#[test]
fn done_is_one_of_the_mutually_exclusive_list_filters() {
    let cli = Cli::new();
    for other in ["--all", "--deleted", "--due"] {
        assert_eq!(cli.run(&["list", "--done", other]).status.code(), Some(2), "--done with {other}");
    }
    assert_eq!(cli.run(&["list", "--done", "--folder", "Notes", "--tag", "x"]).status.code(), Some(0));
}

#[test]
fn move_files_a_note_and_follows_the_mutation_rules() {
    let cli = Cli::new();
    cli.ok(&["folder", "create", "Work"]);
    let id = id_of(&cli.ok(&["note", "file me"]));

    let moved = cli.ok(&["move", &id, "--folder", "work"]);
    assert_eq!((moved["changed"].clone(), moved["item"]["revision"].clone()), (json!(true), json!(2)));
    assert_eq!(moved["item"]["folder"]["name"], "Work");
    let again = cli.ok(&["move", &id, "--folder", "Work", "--if-revision", "1"]);
    assert_eq!(again["changed"], false, "already there beats a stale revision");

    let (code, doc) = cli.json(&["move", &id, "--folder", "Notes", "--if-revision", "1"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (4, "REVISION_CONFLICT"));
    assert!(cli.ok(&["move", &id, "--folder", "Notes", "--if-revision", "2"])["item"]["folder"].is_null());

    let (code, doc) = cli.json(&["move", &id, "--folder", "Nope"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (3, "FOLDER_NOT_FOUND"));
    cli.ok(&["delete", &id]);
    let (code, doc) = cli.json(&["move", &id, "--folder", "Work"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (4, "ITEM_DELETED"));
    assert_eq!(cli.run(&["move", &id]).status.code(), Some(2), "--folder is required");

    let keyed = id_of(&cli.ok(&["note", "idempotent"]));
    let first = cli.ok(&["move", &keyed, "--folder", "Work", "--request-id", "mv-1"]);
    let replay = cli.ok(&["move", &keyed, "--folder", "Work", "--request-id", "mv-1"]);
    assert_eq!((first["replayed"].clone(), replay["replayed"].clone()), (json!(false), json!(true)));
}

#[test]
fn folder_create_rename_and_their_error_codes() {
    let cli = Cli::new();
    cli.ok(&["folder", "create", "Work"]);

    for (args, code, name) in [
        (&["folder", "create", "WORK"][..], 4, "FOLDER_EXISTS"),
        (&["folder", "create", "Notes"][..], 2, "FOLDER_NAME_INVALID"),
        (&["folder", "create", "  "][..], 2, "FOLDER_NAME_INVALID"),
        (&["folder", "rename", "Nope", "X"][..], 3, "FOLDER_NOT_FOUND"),
        (&["folder", "rename", "Work", "Notes"][..], 2, "FOLDER_NAME_INVALID"),
        (&["folder", "rename", "Notes", "Mine"][..], 2, "FOLDER_NAME_INVALID"),
    ] {
        let (exit, doc) = cli.json(args);
        assert_eq!((exit, doc["error"]["code"].as_str().unwrap()), (code, name), "{args:?}");
    }
    let (exit, doc) = cli.json(&["folder", "create", &"a".repeat(51)]);
    assert_eq!((exit, doc["error"]["code"].as_str().unwrap()), (2, "FOLDER_NAME_INVALID"));

    let renamed = cli.ok(&["folder", "rename", "work", "Projects"]);
    assert_eq!(renamed["folder"]["name"], "Projects");
    assert_eq!(renamed["folder"]["revision"], 2);
    assert_eq!(cli.ok(&["folder", "rename", "Projects", "Projects"])["changed"], false);
    assert_eq!(cli.ok(&["folder", "rename", "projects", "PROJECTS"])["folder"]["name"], "PROJECTS", "case-only rename");

    let first = cli.ok(&["folder", "create", "Keyed", "--request-id", "f-1"]);
    let replay = cli.ok(&["folder", "create", "Keyed", "--request-id", "f-1"]);
    assert_eq!(first["folder"]["id"], replay["folder"]["id"]);
    assert_eq!(replay["replayed"], true);
}

#[test]
fn folder_delete_needs_a_choice_when_it_holds_notes_and_reports_what_it_did() {
    let cli = Cli::new();
    cli.ok(&["folder", "create", "Work"]);
    let a = id_of(&cli.ok(&["note", "a", "--folder", "Work"]));
    cli.ok(&["note", "b", "--folder", "Work"]);

    let (code, doc) = cli.json(&["folder", "delete", "Work"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (2, "FOLDER_NOT_EMPTY"));
    assert_eq!(
        doc["error"]["message"],
        "Folder \u{201c}Work\u{201d} holds 2 notes: pass --keep-notes or --delete-notes"
    );
    assert_eq!(cli.run(&["folder", "delete", "Work", "--keep-notes", "--delete-notes"]).status.code(), Some(2));
    assert_eq!(cli.ok(&["folders"])["folders"].as_array().unwrap().len(), 2, "still there");

    let kept = cli.ok(&["folder", "delete", "work", "--keep-notes"]);
    assert_eq!(kept["notes"], "kept");
    assert_eq!((kept["moved"].clone(), kept["deleted"].clone()), (json!(2), json!(0)));
    assert_eq!(kept["folder"]["name"], "Work");
    assert!(cli.ok(&["get", &a])["item"]["folder"].is_null(), "the note is in Notes now");

    cli.ok(&["folder", "create", "Temp"]);
    cli.ok(&["note", "c", "--folder", "Temp"]);
    cli.ok(&["note", "d", "--folder", "Temp"]);
    let deleted = cli.ok(&["folder", "delete", "Temp", "--delete-notes"]);
    assert_eq!(deleted["notes"], "deleted");
    assert_eq!((deleted["moved"].clone(), deleted["deleted"].clone()), (json!(0), json!(2)));
    let mut gone = cli.texts(&["list", "--deleted"]);
    gone.sort(); // both were deleted in the same millisecond
    assert_eq!(gone, ["c", "d"]);

    cli.ok(&["folder", "create", "Empty"]);
    let empty = cli.ok(&["folder", "delete", "Empty"]);
    assert_eq!(
        (empty["notes"].clone(), empty["moved"].clone(), empty["deleted"].clone()),
        (json!("none"), json!(0), json!(0))
    );
    let (code, doc) = cli.json(&["folder", "delete", "Empty"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (3, "FOLDER_NOT_FOUND"));
    let (code, doc) = cli.json(&["folder", "delete", "Notes"]);
    assert_eq!((code, doc["error"]["code"].as_str().unwrap()), (2, "FOLDER_NAME_INVALID"));
}

#[test]
fn human_output_for_the_new_commands() {
    let cli = Cli::new();
    let text = |args: &[&str]| String::from_utf8(cli.run(args).stdout).unwrap();
    assert_eq!(text(&["folder", "create", "Work"]).trim(), "Created folder \u{201c}Work\u{201d}");
    let id = text(&["note", "tagged #bug", "--folder", "Work"]);
    assert!(id.starts_with("Saved"), "{id}");
    assert_eq!(text(&["folders"]).trim(), "Notes  0\nWork  1");
    assert_eq!(text(&["tags"]).trim(), "#bug  1");
    let listed = text(&["list"]);
    let display_id = listed.split_whitespace().next().unwrap().to_owned();
    assert!(text(&["move", &display_id, "--folder", "Notes"]).starts_with("Moved \u{201c}tagged #bug\u{201d}"));
    assert!(text(&["move", &display_id, "--folder", "Notes"]).starts_with("Already in Notes"));
    assert_eq!(
        text(&["folder", "rename", "Work", "Projects"]).trim(),
        "Renamed the folder to \u{201c}Projects\u{201d}"
    );
    assert_eq!(text(&["folder", "delete", "Projects"]).trim(), "Deleted the empty folder \u{201c}Projects\u{201d}");
    assert_eq!(text(&["tags"]).trim(), "#bug  1");
    cli.ok(&["note", "no tags"]);
    cli.ok(&["delete", "--text", "tagged #bug"]);
    assert_eq!(text(&["tags"]).trim(), "No tags.");
}

#[test]
fn the_new_commands_each_emit_one_valid_json_document() {
    let cli = Cli::new();
    for args in [
        &["folders"][..],
        &["tags"][..],
        &["folder", "create", "Work"][..],
        &["folder", "rename", "Work", "Home"][..],
        &["list", "--done"][..],
        &["list", "--folder", "Home", "--tag", "x"][..],
        &["search", "x", "--folder", "Home"][..],
        &["folder", "delete", "Home"][..],
    ] {
        assert_eq!(cli.json(args).0, 0, "{args:?}");
    }
    assert_eq!(cli.json(&["folder", "delete", "Home"]).0, 3);
}

#[test]
fn export_and_import_carry_folders_json_csv_and_dry_run() {
    let source = Cli::new();
    source.ok(&["folder", "create", "Work"]);
    source.ok(&["folder", "create", "Empty"]);
    let filed = id_of(&source.ok(&["note", "filed note", "--folder", "Work"]));
    source.ok(&["note", "loose note"]);
    let out = tempfile::tempdir().unwrap();
    let json_path = out.path().join("backup.json");
    let csv_path = out.path().join("backup.csv");
    source.ok(&["export", "--output", json_path.to_str().unwrap()]);
    source.ok(&["export", "--output", csv_path.to_str().unwrap()]);
    let document: Value = serde_json::from_slice(&std::fs::read(&json_path).unwrap()).unwrap();
    assert_eq!(document["version"], 3);
    assert_eq!(document["folders"].as_array().unwrap().len(), 2);

    let target = Cli::new();
    let dry = target.ok(&["import", "--file", json_path.to_str().unwrap(), "--dry-run"]);
    assert_eq!(
        (dry["new"].clone(), dry["new_folders"].clone(), dry["applied"].clone()),
        (json!(2), json!(2), json!(false))
    );
    assert_eq!(target.ok(&["folders"])["folders"].as_array().unwrap().len(), 1, "a dry run created nothing");
    let human =
        String::from_utf8(target.run(&["import", "--file", json_path.to_str().unwrap(), "--dry-run"]).stdout).unwrap();
    assert!(human.contains("Would create 2 folders."), "{human}");

    let applied = target.ok(&["import", "--file", json_path.to_str().unwrap()]);
    assert_eq!((applied["new"].clone(), applied["new_folders"].clone()), (json!(2), json!(2)));
    assert_eq!(target.ok(&["get", &filed])["item"]["folder"]["name"], "Work");
    assert_eq!(target.ok(&["folders"])["folders"][1]["name"], "Empty");

    let from_csv = Cli::new();
    let applied = from_csv.ok(&["import", "--file", csv_path.to_str().unwrap()]);
    assert_eq!((applied["new"].clone(), applied["new_folders"].clone()), (json!(2), json!(1)));
    assert_eq!(from_csv.texts(&["list", "--folder", "Work"]), ["filed note"]);
}
