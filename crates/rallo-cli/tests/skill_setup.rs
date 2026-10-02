//! Process-level tests for `rallo setup skill` against a temporary $HOME
//! (and, for Codex, a temporary $CODEX_HOME when a test sets one), so the
//! real ~/.claude and ~/.codex are never touched.

use std::fs;
use std::path::{Path, PathBuf};
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

    fn home(&self) -> PathBuf {
        self.dir.path().join("Home With Spaces")
    }

    fn claude_skill(&self) -> PathBuf {
        self.home().join(".claude/skills/rallo/SKILL.md")
    }

    fn codex_skill(&self) -> PathBuf {
        self.home().join(".codex/skills/rallo/SKILL.md")
    }

    fn codex_rules(&self) -> PathBuf {
        self.home().join(".codex/rules/rallo.rules")
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_rallo"));
        command
            .args(["setup", "skill", "--json"])
            .args(args)
            .env("HOME", self.home())
            .env("PATH", "/usr/bin:/bin")
            .env_remove("RALLO_DATA_DIR")
            .env_remove("CODEX_HOME")
            .env_remove("GROK_HOME");
        command
    }

    fn run(&self, args: &[&str]) -> (i32, Value) {
        run(&mut self.command(args))
    }

    fn run_with_codex_home(&self, args: &[&str], codex_home: &Path) -> (i32, Value) {
        let mut command = self.command(args);
        command.env("CODEX_HOME", codex_home);
        run(&mut command)
    }
}

fn run(command: &mut Command) -> (i32, Value) {
    let output = command.output().unwrap();
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(stdout.lines().count(), 1, "exactly one JSON document: {stdout:?}");
    (output.status.code().unwrap(), serde_json::from_str(&stdout).unwrap())
}

/// The `installs` entry for `agent` ("claude"/"codex").
fn install<'a>(doc: &'a Value, agent: &str) -> &'a Value {
    doc["skill"]["installs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|install| install["agent"] == agent)
        .unwrap_or_else(|| panic!("no {agent} install in {doc}"))
}

#[test]
fn no_agent_detected_defaults_to_claude_only() {
    let home = Home::new();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["skill"]["installs"].as_array().unwrap().len(), 1, "{doc}");
    let claude = install(&doc, "claude");
    assert_eq!(claude["status"], "installed");
    assert_eq!(claude["path"], home.claude_skill().to_str().unwrap());
    assert!(claude["rules"].is_null());
    assert_eq!(fs::read_to_string(home.claude_skill()).unwrap(), SKILL);
    assert!(!home.home().join(".codex").exists(), "codex was neither detected nor requested");
    // No `rallo` on this PATH: agents couldn't run it yet.
    assert!(doc["warnings"][0].as_str().unwrap().contains("rallo setup terminal"), "{doc}");

    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0);
    assert_eq!(install(&doc, "claude")["status"], "already_installed");
}

#[test]
fn only_claude_is_targeted_when_only_dot_claude_exists() {
    let home = Home::new();
    fs::create_dir_all(home.home().join(".claude")).unwrap();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0, "{doc}");
    let installs = doc["skill"]["installs"].as_array().unwrap();
    assert_eq!(installs.len(), 1, "{doc}");
    assert_eq!(installs[0]["agent"], "claude");
}

#[test]
fn updates_an_older_rallo_skill() {
    let home = Home::new();
    fs::create_dir_all(home.claude_skill().parent().unwrap()).unwrap();
    fs::write(home.claude_skill(), "---\nname: rallo\ndescription: an older version\n---\n").unwrap();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "claude")["status"], "updated");
    assert_eq!(fs::read_to_string(home.claude_skill()).unwrap(), SKILL);
}

#[test]
fn never_replaces_a_skill_that_is_not_rallos() {
    let home = Home::new();
    fs::create_dir_all(home.claude_skill().parent().unwrap()).unwrap();
    let foreign = "---\nname: someone-elses\n---\nmine\n";
    fs::write(home.claude_skill(), foreign).unwrap();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 4, "{doc}");
    assert_eq!(doc["error"]["code"], "SKILL_CONFLICT");
    assert_eq!(fs::read_to_string(home.claude_skill()).unwrap(), foreign);
}

#[test]
fn print_writes_the_skill_and_installs_nothing() {
    let home = Home::new();
    let (code, doc) = home.run(&["--print"]);
    assert_eq!(code, 0);
    assert_eq!(doc["skill"]["content"], SKILL);
    assert!(!home.claude_skill().exists());
    assert!(!home.codex_skill().exists());
}

#[test]
fn both_detected_installs_both_with_rules_for_codex() {
    let home = Home::new();
    fs::create_dir_all(home.home().join(".claude")).unwrap();
    fs::create_dir_all(home.home().join(".codex")).unwrap();
    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["skill"]["installs"].as_array().unwrap().len(), 2, "{doc}");

    let claude = install(&doc, "claude");
    assert_eq!(claude["status"], "installed");
    assert!(claude["rules"].is_null());
    assert_eq!(fs::read_to_string(home.claude_skill()).unwrap(), SKILL);

    let codex = install(&doc, "codex");
    assert_eq!(codex["status"], "installed");
    assert_eq!(codex["path"], home.codex_skill().to_str().unwrap());
    assert_eq!(codex["rules"]["status"], "installed");
    assert_eq!(codex["rules"]["path"], home.codex_rules().to_str().unwrap());
    assert_eq!(fs::read_to_string(home.codex_skill()).unwrap(), SKILL);

    let rules = fs::read_to_string(home.codex_rules()).unwrap();
    assert!(rules.contains("--json"), "{rules}");
    assert!(!rules.contains("update"), "{rules}");

    let (code, doc) = home.run(&[]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "claude")["status"], "already_installed");
    assert_eq!(install(&doc, "codex")["status"], "already_installed");
    assert_eq!(install(&doc, "codex")["rules"]["status"], "already_installed");
}

#[test]
fn agent_codex_alone_installs_only_codex_and_creates_its_dirs() {
    let home = Home::new();
    let (code, doc) = home.run(&["--agent", "codex"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(doc["skill"]["installs"].as_array().unwrap().len(), 1, "{doc}");
    assert_eq!(install(&doc, "codex")["status"], "installed");
    assert!(home.codex_skill().is_file());
    assert!(home.codex_rules().is_file());
    assert!(!home.home().join(".claude").exists(), "claude was not requested");
}

#[test]
fn grok_home_env_var_is_honoured() {
    let home = Home::new();
    let custom = tempfile::tempdir().unwrap();
    let mut command = home.command(&["--agent", "grok"]);
    command.env("GROK_HOME", custom.path());
    let (code, doc) = run(&mut command);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "grok")["path"], custom.path().join("skills/rallo/SKILL.md").to_str().unwrap());
    assert!(!home.home().join(".grok").exists(), "the $HOME/.grok fallback must not be used");
}

#[test]
fn codex_home_env_var_is_honoured() {
    let home = Home::new();
    let custom = tempfile::tempdir().unwrap();
    let (code, doc) = home.run_with_codex_home(&[], custom.path());
    assert_eq!(code, 0, "{doc}");
    // Only $CODEX_HOME is a directory here, so only Codex is detected.
    assert_eq!(doc["skill"]["installs"].as_array().unwrap().len(), 1, "{doc}");
    let codex = install(&doc, "codex");
    assert_eq!(codex["path"], custom.path().join("skills/rallo/SKILL.md").to_str().unwrap());
    assert_eq!(codex["rules"]["path"], custom.path().join("rules/rallo.rules").to_str().unwrap());
    assert!(!home.home().join(".codex").exists(), "the $HOME/.codex fallback must not be used");
}

#[test]
fn outdated_codex_rules_are_updated() {
    let home = Home::new();
    fs::create_dir_all(home.codex_rules().parent().unwrap()).unwrap();
    let stale = "# Rallo 0.0.0: written by `rallo setup skill`. An older shape\n# entirely.\n";
    fs::write(home.codex_rules(), stale).unwrap();

    let (code, doc) = home.run(&["--agent", "codex"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "codex")["rules"]["status"], "updated");
    let updated = fs::read_to_string(home.codex_rules()).unwrap();
    assert_ne!(updated, stale);
    assert!(updated.contains("--json"), "{updated}");

    let (code, doc) = home.run(&["--agent", "codex"]);
    assert_eq!(code, 0, "{doc}");
    assert_eq!(install(&doc, "codex")["rules"]["status"], "already_installed");
}

#[test]
fn foreign_codex_rules_block_the_whole_install() {
    let home = Home::new();
    fs::create_dir_all(home.home().join(".claude")).unwrap();
    fs::create_dir_all(home.codex_rules().parent().unwrap()).unwrap();
    let foreign = "# not Rallo's\nprefix_rule(pattern=[\"ls\"], decision=\"allow\")\n";
    fs::write(home.codex_rules(), foreign).unwrap();

    let (code, doc) = home.run(&[]);
    assert_eq!(code, 4, "{doc}");
    assert_eq!(doc["error"]["code"], "SKILL_CONFLICT");
    assert!(doc["error"]["message"].as_str().unwrap().contains(home.codex_rules().to_str().unwrap()), "{doc}");
    assert_eq!(fs::read_to_string(home.codex_rules()).unwrap(), foreign);
    assert!(!home.claude_skill().exists(), "nothing is written for any target on a conflict");
    assert!(!home.codex_skill().exists());
}

#[test]
fn foreign_codex_skill_blocks_claude_too() {
    let home = Home::new();
    fs::create_dir_all(home.home().join(".claude")).unwrap();
    fs::create_dir_all(home.codex_skill().parent().unwrap()).unwrap();
    let foreign = "---\nname: someone-elses\n---\nmine\n";
    fs::write(home.codex_skill(), foreign).unwrap();

    let (code, doc) = home.run(&[]);
    assert_eq!(code, 4, "{doc}");
    assert_eq!(doc["error"]["code"], "SKILL_CONFLICT");
    assert!(doc["error"]["message"].as_str().unwrap().contains(home.codex_skill().to_str().unwrap()), "{doc}");
    assert_eq!(fs::read_to_string(home.codex_skill()).unwrap(), foreign);
    assert!(!home.claude_skill().exists(), "nothing is written for any target on a conflict");
}
