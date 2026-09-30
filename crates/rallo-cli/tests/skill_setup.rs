//! Process-level tests for `rallo setup skill` against a temporary $HOME, so
//! the real ~/.claude/skills is never touched.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

use serde_json::Value;

const SKILL: &str = include_str!("../../../skills/rallo/SKILL.md");

struct Home {
    dir: tempfile::TempDir,
}

impl Home {
    fn new() -> Self {
        Self { dir: tempfile::tempdir().unwrap() }
    }

    fn skill(&self) -> PathBuf {
        self.dir.path().join("Home With Spaces/.claude/skills/rallo/SKILL.md")
    }

    fn run(&self, args: &[&str]) -> (i32, Value) {
        let output = Command::new(env!("CARGO_BIN_EXE_rallo"))
            .args(["setup", "skill", "--json"])
            .args(args)
            .env("HOME", self.dir.path().join("Home With Spaces"))
            .env("PATH", "/usr/bin:/bin")
            .env_remove("RALLO_DATA_DIR")
            .output()
            .unwrap();
        let stdout = String::from_utf8(output.stdout).unwrap();
        assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
        (output.status.code().unwrap(), serde_json::from_str(&stdout).unwrap())
    }
}

#[test]
fn installs_then_reports_already_installed() {
    let home = Home::new();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["skill"]["status"], "installed");
    assert_eq!(doc["skill"]["path"], home.skill().to_str().unwrap());
    assert_eq!(fs::read_to_string(home.skill()).unwrap(), SKILL);
    // No `rallo` on this PATH: agents couldn't run it yet.
    assert!(doc["warnings"][0].as_str().unwrap().contains("rallo setup terminal"), "{doc}");

    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0);
    assert_eq!(doc["skill"]["status"], "already_installed");
}

#[test]
fn updates_an_older_rallo_skill() {
    let home = Home::new();
    fs::create_dir_all(home.skill().parent().unwrap()).unwrap();
    fs::write(home.skill(), "---\nname: rallo\ndescription: an older version\n---\n").unwrap();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["skill"]["status"], "updated");
    assert_eq!(fs::read_to_string(home.skill()).unwrap(), SKILL);
}

#[test]
fn never_replaces_a_skill_that_is_not_rallos() {
    let home = Home::new();
    fs::create_dir_all(home.skill().parent().unwrap()).unwrap();
    let foreign = "---\nname: someone-elses\n---\nmine\n";
    fs::write(home.skill(), foreign).unwrap();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 4, "{doc}");
    assert_eq!(doc["error"]["code"], "SKILL_CONFLICT");
    assert_eq!(fs::read_to_string(home.skill()).unwrap(), foreign);
}

#[test]
fn print_writes_the_skill_and_installs_nothing() {
    let home = Home::new();
    let (code, doc) = home.run(&["--print"]);
    assert_eq!(code, 0);
    assert_eq!(doc["skill"]["content"], SKILL);
    assert!(!home.skill().exists());
}
