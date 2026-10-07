//! Images on notes (0018) through the CLI. Each test uses its own data directory.

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

const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDRfake";

fn png(cli: &Cli, name: &str) -> String {
    let path = cli.dir.path().join(name);
    std::fs::write(&path, PNG).unwrap();
    path.to_str().unwrap().to_owned()
}

#[test]
fn note_with_an_image() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    let (code, json) = cli.json(&["note", "Login broken", "--image", &shot, "--json"]);
    assert_eq!(code, 0);
    let image = &json["item"]["images"][0];
    assert_eq!(image["type"], "image/png");
    assert_eq!(image["bytes"], PNG.len());
    let stored = image["path"].as_str().unwrap();
    assert_ne!(stored, shot, "Rallo keeps its own copy");
    assert_eq!(std::fs::read(stored).unwrap(), PNG);
    std::fs::remove_file(&shot).unwrap();
    assert!(std::path::Path::new(stored).exists());
}

#[test]
fn an_image_alone_is_enough() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    let (code, json) = cli.json(&["note", "--image", &shot, "--json"]);
    assert_eq!(code, 0);
    assert_eq!(json["item"]["text"], "");
    let human = cli.run(&["note", "--image", &shot]);
    assert!(String::from_utf8_lossy(&human.stdout).contains("image"));
}

#[test]
fn refusals_exit_2_and_save_nothing() {
    let cli = Cli::new();
    let text_file = cli.dir.path().join("notes.png");
    std::fs::write(&text_file, b"not an image").unwrap();
    let (code, json) = cli.json(&["note", "x", "--image", text_file.to_str().unwrap(), "--json"]);
    assert_eq!(code, 2);
    assert_eq!(json["error"]["code"], "IMAGE_UNSUPPORTED");
    let (code, json) = cli.json(&["note", "x", "--image", "/nonexistent/shot.png", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(json["error"]["code"], "IMAGE_UNREADABLE");
    let (_, list) = cli.json(&["list", "--json"]);
    assert_eq!(list["items"].as_array().unwrap().len(), 0);
}

#[test]
fn attach_and_detach() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    let (_, created) = cli.json(&["note", "x", "--json"]);
    let id = created["item"]["id"].as_str().unwrap().to_owned();
    let (code, attached) = cli.json(&["attach", &id, &shot, &shot, "--json"]);
    assert_eq!(code, 0);
    assert_eq!(attached["item"]["images"].as_array().unwrap().len(), 2);
    let image_id = attached["item"]["images"][0]["id"].as_str().unwrap().to_owned();
    let (code, detached) = cli.json(&["detach", &id, &image_id, "--json"]);
    assert_eq!(code, 0);
    assert_eq!(detached["item"]["images"].as_array().unwrap().len(), 1);
    let (code, missing) = cli.json(&["detach", &id, &image_id, "--json"]);
    assert_eq!(code, 3);
    assert_eq!(missing["error"]["code"], "IMAGE_NOT_FOUND");
}

#[test]
fn a_zip_export_imports_into_another_data_directory() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    cli.json(&["note", "with image", "--image", &shot, "--json"]);
    let archive = cli.dir.path().join("export.zip");
    let (code, exported) = cli.json(&["export", "--output", archive.to_str().unwrap(), "--json"]);
    assert_eq!(code, 0, "{exported}");
    assert_eq!(exported["export"]["format"], "zip");

    let other = Cli::new();
    let (code, imported) = other.json(&["import", "--file", archive.to_str().unwrap(), "--json"]);
    assert_eq!(code, 0, "{imported}");
    let (_, list) = other.json(&["list", "--json"]);
    let image_path = list["items"][0]["images"][0]["path"].as_str().unwrap().to_owned();
    // Image paths sit under the canonical data directory (/private/var, not /var).
    let canonical = std::fs::canonicalize(other.dir.path()).unwrap();
    assert!(std::path::Path::new(&image_path).starts_with(canonical), "{image_path}");
    assert_eq!(std::fs::read(image_path).unwrap(), PNG);
}

#[test]
fn a_reminder_with_an_image() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    let (code, json) = cli.json(&["remind", "x", "--in", "1h", "--image", &shot, "--json"]);
    assert_eq!(code, 0, "{json}");
    assert_eq!(json["item"]["images"].as_array().unwrap().len(), 1);
    assert!(json["item"]["reminder"].is_object());
}

#[test]
fn a_hostile_zip_is_refused_and_imports_nothing() {
    let cli = Cli::new();
    let build = cli.dir.path().join("build");
    std::fs::create_dir(&build).unwrap();
    std::fs::write(build.join("rallo-export.json"), b"{}").unwrap();
    std::fs::write(build.join("notes.txt"), b"hi").unwrap();
    let archive = cli.dir.path().join("bad.zip");
    let status = Command::new("/usr/bin/zip")
        .current_dir(&build)
        .args(["-q", archive.to_str().unwrap(), "rallo-export.json", "notes.txt"])
        .status()
        .unwrap();
    assert!(status.success());
    let (code, json) = cli.json(&["import", "--file", archive.to_str().unwrap(), "--json"]);
    assert_eq!(code, 2, "{json}");
    assert_eq!(json["error"]["code"], "INVALID_IMPORT");
    let (_, list) = cli.json(&["list", "--all", "--json"]);
    assert_eq!(list["items"].as_array().unwrap().len(), 0);
}

#[test]
fn a_json_export_warns_about_images() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    cli.json(&["note", "with image", "--image", &shot, "--json"]);
    let out = cli.dir.path().join("export.json");
    let (code, json) = cli.json(&["export", "--output", out.to_str().unwrap(), "--json"]);
    assert_eq!(code, 0);
    assert_eq!(json["warnings"][0], "1 image isn't included; use --format zip");
}

#[test]
fn a_zip_export_needs_a_file() {
    let cli = Cli::new();
    let (code, json) = cli.json(&["export", "--output", "-", "--format", "zip", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(json["error"]["code"], "INVALID_INPUT");
}

fn images_check(cli: &Cli) -> Value {
    let json = parse(&cli.run(&["doctor", "--json"]));
    json["checks"].as_array().unwrap().iter().find(|check| check["id"] == "images").unwrap().clone()
}

#[test]
fn doctor_reports_images() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    cli.json(&["note", "x", "--image", &shot, "--json"]);
    let check = images_check(&cli);
    assert_eq!(check["status"], "ok");
    assert!(check["summary"].as_str().unwrap().starts_with("1 image"));
}

#[test]
fn doctor_reports_a_missing_image_file() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    let (_, created) = cli.json(&["note", "x", "--image", &shot, "--json"]);
    std::fs::remove_file(created["item"]["images"][0]["path"].as_str().unwrap()).unwrap();
    let check = images_check(&cli);
    assert_eq!(check["status"], "problem");
    assert!(check["summary"].as_str().unwrap().contains("1 missing"));
}

#[test]
fn a_zip_dry_run_reports_the_zip_format() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    cli.json(&["note", "with image", "--image", &shot, "--json"]);
    let archive = cli.dir.path().join("export.zip");
    cli.json(&["export", "--output", archive.to_str().unwrap(), "--json"]);
    let other = Cli::new();
    let (code, report) = other.json(&["import", "--file", archive.to_str().unwrap(), "--dry-run", "--json"]);
    assert_eq!(code, 0, "{report}");
    assert_eq!(report["format"], "zip");
}

#[test]
fn searching_for_blank_text_says_the_search_text_is_empty() {
    let cli = Cli::new();
    let (code, json) = cli.json(&["search", " ", "--json"]);
    assert_eq!(code, 2);
    assert_eq!(json["error"]["message"], "search text is empty");
}

#[test]
fn an_endless_image_file_is_refused_as_too_large() {
    let cli = Cli::new();
    let (code, json) = cli.json(&["note", "x", "--image", "/dev/zero", "--json"]);
    assert_eq!(code, 2, "{json}");
    assert_eq!(json["error"]["code"], "IMAGE_TOO_LARGE");
}

#[test]
fn export_to_stdout_warns_on_stderr_about_left_out_notes() {
    let cli = Cli::new();
    let shot = png(&cli, "shot.png");
    cli.json(&["note", "--image", &shot, "--json"]);
    let output = cli.run(&["export", "--output", "-"]);
    assert!(output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("1 image-only note was left out"), "{stderr}");
}
