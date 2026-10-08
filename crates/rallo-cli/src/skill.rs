//! The agent skill (`skills/rallo/SKILL.md`), embedded so it always matches
//! this CLI's version, and the agents `rallo setup skill` installs it for:
//! Claude Code's personal skills directory (`~/.claude/skills`, which Cursor
//! also reads) and Codex's (`~/.codex/skills`, or `$CODEX_HOME` -- shared by
//! the Codex CLI and the Codex tab of the ChatGPT desktop app), Grok's
//! (`~/.grok/skills`, or `$GROK_HOME`), and Gemini CLI's (`~/.gemini/skills`,
//! or under `$GEMINI_CLI_HOME`). Codex also
//! gets `rallo.rules`, an execpolicy file pre-approving Rallo's everyday
//! commands, because its default sandbox blocks the notes store in
//! `~/Library` otherwise.

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const SKILL: &str = include_str!("../../../skills/rallo/SKILL.md");

/// Subcommands (0003) safe to pre-approve for Codex without asking: everyday
/// notes/reminders only. Never `update`, `setup`, `backup`, `import`,
/// `export`, `doctor`, or `folder` (its create/rename/delete stay behind
/// Codex's approval prompt).
const RULES_COMMANDS: [&str; 21] = [
    "note",
    "remind",
    "list",
    "get",
    "search",
    "done",
    "reopen",
    "snooze",
    "reschedule",
    "acknowledge",
    "cancel-reminder",
    "edit",
    "delete",
    "attach",
    "detach",
    "restore",
    "show",
    "hide",
    "folders",
    "tags",
    "move",
];

pub enum State {
    Missing,
    Current,
    /// Rallo's own (skill or rules), but not this version's text.
    Outdated,
    /// Something else occupies the path.
    Foreign,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum Agent {
    Claude,
    Codex,
    Grok,
    Gemini,
}

impl Agent {
    pub const ALL: [Agent; 4] = [Agent::Claude, Agent::Codex, Agent::Grok, Agent::Gemini];

    pub fn json_name(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
            Agent::Grok => "grok",
            Agent::Gemini => "gemini",
        }
    }

    /// How this agent is named in human-readable output.
    pub fn label(self) -> &'static str {
        match self {
            Agent::Claude => "Claude Code and Cursor",
            Agent::Codex => "Codex",
            Agent::Grok => "Grok",
            Agent::Gemini => "Gemini CLI",
        }
    }
}

/// Claude Code's personal skills directory, which Cursor also reads.
pub(crate) fn claude_home(home: &Path) -> PathBuf {
    home.join(".claude")
}

/// `$CODEX_HOME` if set and non-empty, else `$HOME/.codex` -- shared by the
/// Codex CLI and the Codex tab of the ChatGPT desktop app.
pub(crate) fn codex_home(home: &Path) -> PathBuf {
    match env::var_os("CODEX_HOME").filter(|value| !value.is_empty()) {
        Some(value) => PathBuf::from(value),
        None => home.join(".codex"),
    }
}

/// `$GROK_HOME` if set and non-empty, else `$HOME/.grok`.
pub(crate) fn grok_home(home: &Path) -> PathBuf {
    match env::var_os("GROK_HOME").filter(|value| !value.is_empty()) {
        Some(value) => PathBuf::from(value),
        None => home.join(".grok"),
    }
}

/// `$GEMINI_CLI_HOME/.gemini` if the variable is set and non-empty, else
/// `$HOME/.gemini` (unlike `$GROK_HOME`, the variable replaces the home, not
/// the `.gemini` folder).
pub(crate) fn gemini_home(home: &Path) -> PathBuf {
    match env::var_os("GEMINI_CLI_HOME").filter(|value| !value.is_empty()) {
        Some(value) => PathBuf::from(value).join(".gemini"),
        None => home.join(".gemini"),
    }
}

/// Whether `agent`'s home directory exists on this machine, i.e. whether it
/// looks worth installing for without being asked.
pub fn detected(agent: Agent, home: &Path) -> bool {
    match agent {
        Agent::Claude => claude_home(home).is_dir(),
        Agent::Codex => codex_home(home).is_dir(),
        Agent::Grok => grok_home(home).is_dir(),
        // Google's Antigravity IDE also creates `~/.gemini`; only the CLI's
        // settings file proves Gemini CLI itself.
        Agent::Gemini => gemini_home(home).join("settings.json").is_file(),
    }
}

pub fn skill_path(agent: Agent, home: &Path) -> PathBuf {
    match agent {
        Agent::Claude => claude_home(home).join("skills/rallo/SKILL.md"),
        Agent::Codex => codex_home(home).join("skills/rallo/SKILL.md"),
        Agent::Grok => grok_home(home).join("skills/rallo/SKILL.md"),
        Agent::Gemini => gemini_home(home).join("skills/rallo/SKILL.md"),
    }
}

/// Codex's execpolicy rules file pre-approving Rallo's everyday commands.
pub fn rules_path(home: &Path) -> PathBuf {
    codex_home(home).join("rules/rallo.rules")
}

/// The generated `rallo.rules` (Codex execpolicy Starlark) for a given
/// `$HOME`: deterministic for that `home` and this CLI's version, so
/// `inspect_rules` can compare it byte-for-byte like the skill. Pre-approves
/// `rallo` on PATH plus the two absolute fallback paths the skill names,
/// each for the everyday commands (bare and under `--json`) and
/// `--version`.
pub fn rules_content(home: &Path) -> String {
    let version = env!("CARGO_PKG_VERSION");
    let commands = RULES_COMMANDS.iter().map(|command| format!("\"{command}\"")).collect::<Vec<_>>().join(", ");
    let subjects = [
        "rallo".to_owned(),
        home.join("Applications/Rallo.app/Contents/Helpers/rallo").display().to_string(),
        "/Applications/Rallo.app/Contents/Helpers/rallo".to_owned(),
    ];

    let mut text = format!(
        "# Rallo {version}: written by `rallo setup skill`. Lets Codex run Rallo's\n\
         # everyday note commands without asking (outside its sandbox, because notes\n\
         # live in ~/Library). Delete this file to undo.\n"
    );
    for subject in subjects {
        // A Starlark string literal: an unescaped quote in a home path would
        // make Codex reject the whole file.
        let subject = subject.replace('\\', "\\\\").replace('"', "\\\"");
        text.push_str(&format!(
            "prefix_rule(pattern=[\"{subject}\", [{commands}]], decision=\"allow\")\n\
             prefix_rule(pattern=[\"{subject}\", \"--json\", [{commands}]], decision=\"allow\")\n\
             prefix_rule(pattern=[\"{subject}\", \"--version\"], decision=\"allow\")\n"
        ));
    }
    text
}

fn inspect(path: &Path, current: &str, same_family: impl Fn(&str) -> bool) -> State {
    match fs::read_to_string(path) {
        Ok(text) if text == current => State::Current,
        Ok(text) if same_family(&text) => State::Outdated,
        Err(error) if error.kind() == io::ErrorKind::NotFound => State::Missing,
        _ => State::Foreign,
    }
}

pub fn inspect_skill(path: &Path) -> State {
    inspect(path, SKILL, |text| text.lines().any(|line| line.trim() == "name: rallo"))
}

pub fn inspect_rules(path: &Path, current: &str) -> State {
    inspect(path, current, |text| {
        text.lines()
            .next()
            .is_some_and(|line| line.starts_with("# Rallo ") && line.contains("written by `rallo setup skill`"))
    })
}

/// Writes through a temporary file and a rename, so an agent never reads a
/// half-written skill or rules file.
fn write_atomic(path: &Path, content: &str) -> io::Result<()> {
    let dir = path.parent().expect("path has a parent");
    fs::create_dir_all(dir)?;
    let file_name = path.file_name().expect("path has a file name");
    let mut temp_name = std::ffi::OsString::from(".");
    temp_name.push(file_name);
    temp_name.push(".tmp");
    let temporary = dir.join(temp_name);
    fs::write(&temporary, content)?;
    fs::rename(&temporary, path)
}

pub fn install_skill(path: &Path) -> io::Result<()> {
    write_atomic(path, SKILL)
}

pub fn install_rules(path: &Path, content: &str) -> io::Result<()> {
    write_atomic(path, content)
}
