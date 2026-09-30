//! `rallo setup hooks` (0007): installs the `agent-event` hook command into
//! Claude Code's `~/.claude/settings.json` `hooks` and Codex's
//! `$CODEX_HOME/hooks.json` `hooks`.
//!
//! Both files are arbitrary JSON a person (or another tool) may already have
//! populated, and 0007 requires preserving everything Rallo doesn't own,
//! *including key order*. `serde_json::Value`'s `Map` can only do that with
//! the crate-wide `preserve_order` feature, which -- because Cargo unifies
//! features for one crate version across a whole binary -- would also
//! reorder every other command's `Map`-built JSON envelope (`output.rs`),
//! breaking `docs/cli-contract.md`'s "keys are sorted". `OrderedValue` below
//! is a small parallel JSON tree backed by `indexmap::IndexMap` instead, used
//! only in this module, so reads and writes here round-trip any untouched
//! key in its original order regardless of that global feature.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use serde_json::{Number, Value, json};

use crate::commands::CommandResult;
use crate::output::{Exit, Failure, Output};
use crate::skill::{self, Agent};
use rallo_platform_macos::terminal_command;

/// Claude Code's `PermissionRequest`/`PostToolUse`/etc. hook events this
/// build installs (0007). Order matches the spec table; it is also the
/// order `--print` shows them in.
const CLAUDE_EVENTS: [&str; 6] =
    ["PermissionRequest", "Notification", "PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd"];
const CODEX_EVENTS: [&str; 6] =
    ["PermissionRequest", "PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd", "Interrupt"];

fn events_for(agent: Agent) -> &'static [&'static str] {
    match agent {
        Agent::Claude => &CLAUDE_EVENTS,
        Agent::Codex => &CODEX_EVENTS,
    }
}

/// Distinct from `skill::Agent::label` ("Claude Code and Cursor"): Cursor
/// does not read Claude Code's hook settings, so hooks only ever name Claude
/// Code itself. Used by `doctor`'s `agent_hooks` check too.
pub(crate) fn hook_label(agent: Agent) -> &'static str {
    match agent {
        Agent::Claude => "Claude Code",
        Agent::Codex => "Codex",
    }
}

pub(crate) fn hooks_path(agent: Agent, home: &Path) -> PathBuf {
    match agent {
        Agent::Claude => skill::claude_home(home).join("settings.json"),
        Agent::Codex => skill::codex_home(home).join("hooks.json"),
    }
}

/// A JSON tree that preserves object key order and array order exactly as
/// parsed, so untouched parts of a hooks file round-trip unchanged. Object
/// equality (used to detect a no-op install) is order-insensitive, like any
/// JSON object; array equality is order-sensitive, like any JSON array.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
enum OrderedValue {
    Null,
    Bool(bool),
    Number(Number),
    String(String),
    Array(Vec<OrderedValue>),
    Object(IndexMap<String, OrderedValue>),
}

impl OrderedValue {
    fn object() -> Self {
        Self::Object(IndexMap::new())
    }

    fn as_object(&self) -> Option<&IndexMap<String, OrderedValue>> {
        match self {
            Self::Object(map) => Some(map),
            _ => None,
        }
    }

    fn as_object_mut(&mut self) -> Option<&mut IndexMap<String, OrderedValue>> {
        match self {
            Self::Object(map) => Some(map),
            _ => None,
        }
    }

    fn as_array(&self) -> Option<&Vec<OrderedValue>> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    fn as_array_mut(&mut self) -> Option<&mut Vec<OrderedValue>> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s),
            _ => None,
        }
    }
}

/// `"<abs cli path>" agent-event --agent <claude|codex>` (0007): the path is
/// quoted because hooks run without an interactive shell's word-splitting
/// rules, and a `Home With Spaces` install path is real (other setup
/// commands are tested against one).
fn command_string(cli_path: &Path, agent: Agent) -> String {
    format!("\"{}\" agent-event --agent {}", cli_path.display(), agent.json_name())
}

/// Rallo's own entries are recognised by shape, not by an exact path match,
/// so a stale entry from a moved/reinstalled copy is still found and
/// replaced (0007).
fn is_rallo_command(command: &str) -> bool {
    command.contains("/Rallo.app/Contents/Helpers/rallo") && command.contains(" agent-event --agent ")
}

/// The quoted leading path of a Rallo command string, e.g. `/Applications/
/// Rallo.app/Contents/Helpers/rallo` from `"<path>" agent-event --agent
/// claude`. Used by `doctor`'s `agent_hooks` check too.
pub(crate) fn extract_cli_path(command: &str) -> Option<&str> {
    let rest = command.strip_prefix('"')?;
    let end = rest.find('"')?;
    Some(&rest[..end])
}

fn one_hook_group(command: &str) -> OrderedValue {
    OrderedValue::Object(IndexMap::from([(
        "hooks".to_owned(),
        OrderedValue::Array(vec![OrderedValue::Object(IndexMap::from([
            ("type".to_owned(), OrderedValue::String("command".to_owned())),
            ("command".to_owned(), OrderedValue::String(command.to_owned())),
            ("timeout".to_owned(), OrderedValue::Number(Number::from(10))),
        ]))]),
    )]))
}

fn default_content(agent: Agent) -> OrderedValue {
    match agent {
        Agent::Claude => OrderedValue::object(),
        Agent::Codex => OrderedValue::Object(IndexMap::from([("hooks".to_owned(), OrderedValue::object())])),
    }
}

/// Removes every Rallo-recognised command entry anywhere under `hooks.*`,
/// dropping an emptied group/event-array/`hooks` key -- but only a container
/// this pass itself emptied, never one that started out empty on its own
/// (0007: "dropping groups/arrays/`hooks` key only if they become empty AND
/// Rallo emptied them"). Returns the number of command entries removed.
fn remove_rallo_entries(root: &mut OrderedValue) -> usize {
    let mut removed = 0;
    let Some(root_obj) = root.as_object_mut() else { return 0 };
    let Some(hooks_obj) = root_obj.get_mut("hooks").and_then(OrderedValue::as_object_mut) else { return 0 };

    let mut empty_events = Vec::new();
    for (event_name, groups_value) in hooks_obj.iter_mut() {
        let Some(groups) = groups_value.as_array_mut() else { continue };
        let mut event_changed = false;
        groups.retain_mut(|group| {
            let Some(inner) =
                group.as_object_mut().and_then(|group| group.get_mut("hooks")).and_then(OrderedValue::as_array_mut)
            else {
                return true;
            };
            let before = inner.len();
            inner.retain(|entry| {
                let is_rallo = entry
                    .as_object()
                    .and_then(|entry| entry.get("command"))
                    .and_then(OrderedValue::as_str)
                    .is_some_and(is_rallo_command);
                if is_rallo {
                    removed += 1;
                }
                !is_rallo
            });
            let removed_here = inner.len() != before;
            event_changed |= removed_here;
            // Keep the group unless this pass just emptied it.
            !(removed_here && inner.is_empty())
        });
        if event_changed && groups.is_empty() {
            empty_events.push(event_name.clone());
        }
    }
    for event_name in empty_events {
        hooks_obj.shift_remove(&event_name);
    }
    if removed > 0 && hooks_obj.is_empty() {
        root_obj.shift_remove("hooks");
    }
    removed
}

/// Appends one fresh group per event in `events_for(agent)`, creating
/// `hooks`/the event's array if absent. A `hooks`/event value that already
/// exists but isn't an object/array (a very unusual hand-edited file) is
/// left untouched rather than overwritten or panicking.
fn append_rallo_groups(root: &mut OrderedValue, agent: Agent, cli_path: &Path) {
    let command = command_string(cli_path, agent);
    let Some(root_obj) = root.as_object_mut() else { return };
    let hooks_value = root_obj.entry("hooks".to_owned()).or_insert_with(OrderedValue::object);
    let Some(hooks_obj) = hooks_value.as_object_mut() else { return };
    for event in events_for(agent) {
        let groups = hooks_obj.entry((*event).to_owned()).or_insert_with(|| OrderedValue::Array(Vec::new()));
        let Some(groups) = groups.as_array_mut() else { continue };
        groups.push(one_hook_group(&command));
    }
}

enum Loaded {
    Existing(OrderedValue),
    Missing,
    Invalid,
}

fn load(path: &Path) -> Loaded {
    match fs::read_to_string(path) {
        Ok(text) => match serde_json::from_str::<OrderedValue>(&text) {
            Ok(value @ OrderedValue::Object(_)) => Loaded::Existing(value),
            _ => Loaded::Invalid,
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => Loaded::Missing,
        Err(_) => Loaded::Invalid,
    }
}

/// Every Rallo command string found in `path`'s `hooks` tree, for `doctor`'s
/// read-only `agent_hooks` check. Never partially parses: an invalid file is
/// reported as such, not silently treated as empty.
pub(crate) enum ReadResult {
    NotPresent,
    Invalid,
    Found(Vec<String>),
}

pub(crate) fn find_rallo_entries(path: &Path) -> ReadResult {
    match load(path) {
        Loaded::Missing => ReadResult::NotPresent,
        Loaded::Invalid => ReadResult::Invalid,
        Loaded::Existing(value) => ReadResult::Found(collect_rallo_commands(&value)),
    }
}

fn collect_rallo_commands(root: &OrderedValue) -> Vec<String> {
    let mut found = Vec::new();
    let Some(hooks_obj) = root.as_object().and_then(|root| root.get("hooks")).and_then(OrderedValue::as_object) else {
        return found;
    };
    for groups in hooks_obj.values() {
        let Some(groups) = groups.as_array() else { continue };
        for group in groups {
            let Some(inner) = group.as_object().and_then(|group| group.get("hooks")).and_then(OrderedValue::as_array)
            else {
                continue;
            };
            for entry in inner {
                if let Some(command) =
                    entry.as_object().and_then(|entry| entry.get("command")).and_then(OrderedValue::as_str)
                    && is_rallo_command(command)
                {
                    found.push(command.to_owned());
                }
            }
        }
    }
    found
}

fn not_installed() -> Failure {
    Failure::new(
        Exit::InvalidInput,
        "NOT_INSTALLED",
        "could not resolve this CLI's location inside an installed Rallo.app; `rallo setup hooks` needs the \
         absolute path hooks will run, so it only works from an installed copy in /Applications or ~/Applications",
    )
}

fn hooks_config_invalid(paths: &[PathBuf]) -> Failure {
    let listed = paths.iter().map(|path| path.display().to_string()).collect::<Vec<_>>().join(", ");
    Failure::new(
        Exit::Conflict,
        "HOOKS_CONFIG_INVALID",
        format!("{listed} is not valid JSON; `rallo setup hooks` will not touch it. Fix or remove it and try again."),
    )
}

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

fn backup_path_for(path: &Path) -> PathBuf {
    let mut name = path.file_name().expect("path has a file name").to_os_string();
    name.push(".rallo-backup");
    path.with_file_name(name)
}

/// Backs up `path` (once ever: skipped if a backup already exists) and
/// writes `value` atomically as pretty JSON with a trailing newline.
fn write_target(path: &Path, value: &OrderedValue, existed: bool) -> io::Result<Option<PathBuf>> {
    let backup_path = if existed {
        let backup = backup_path_for(path);
        if !backup.exists() {
            fs::copy(path, &backup)?;
        }
        Some(backup)
    } else {
        None
    };
    let text = format!("{}\n", serde_json::to_string_pretty(value).expect("OrderedValue serializes"));
    write_atomic(path, &text)?;
    Ok(backup_path)
}

fn targets(agents: Vec<Agent>, home: &Path) -> Vec<Agent> {
    if !agents.is_empty() {
        return agents;
    }
    let detected: Vec<Agent> = Agent::ALL.into_iter().filter(|&agent| skill::detected(agent, home)).collect();
    if detected.is_empty() { vec![Agent::Claude] } else { detected }
}

/// Resolves the absolute CLI path hooks must reference: this executable's
/// own installed location (like `rallo update`). Needed for `install` and
/// `--print` (both show/write a real path); `--remove` never needs it, since
/// Rallo's entries are recognised by shape, not by matching this path.
fn installed_cli_path() -> Result<PathBuf, Failure> {
    let home = terminal_command::home_dir()
        .ok_or_else(|| Failure::new(Exit::InvalidInput, "INVALID_INPUT", "$HOME is not set"))?;
    let app = terminal_command::locate_running_app().map_err(|_| not_installed())?;
    if !terminal_command::is_installed(&app, &home) {
        return Err(not_installed());
    }
    Ok(terminal_command::cli_path(&app))
}

fn human_line(agent: Agent, status: &str, path: &Path) -> String {
    let label = hook_label(agent);
    let headline = match status {
        "installed" => format!("Added Rallo's hooks to {} ({label}).", path.display()),
        "updated" => format!("Updated Rallo's hooks in {} ({label}).", path.display()),
        "already_installed" => format!("Rallo's hooks are already installed in {} ({label}).", path.display()),
        "removed" => format!("Removed Rallo's hooks from {} ({label}).", path.display()),
        "not_present" => format!("No Rallo hooks were present in {} ({label}).", path.display()),
        other => unreachable!("unexpected hooks status {other}"),
    };
    if agent == Agent::Codex && matches!(status, "installed" | "updated") {
        format!("{headline} Codex asks you to trust new hooks the next time it starts.")
    } else {
        headline
    }
}

fn print_groups(out: &Output, agents: Vec<Agent>) -> CommandResult {
    let home = terminal_command::home_dir()
        .ok_or_else(|| Failure::new(Exit::InvalidInput, "INVALID_INPUT", "$HOME is not set"))?;
    let cli_path = installed_cli_path()?;
    let targets = targets(agents, &home);

    let groups: Vec<Value> = targets
        .iter()
        .map(|&agent| {
            let command = command_string(&cli_path, agent);
            let events: Value = events_for(agent)
                .iter()
                .map(|event| {
                    ((*event).to_owned(), serde_json::to_value(one_hook_group(&command)).expect("group serializes"))
                })
                .collect::<serde_json::Map<_, _>>()
                .into();
            json!({ "agent": agent.json_name(), "path": hooks_path(agent, &home), "events": events })
        })
        .collect();

    out.success(json!({ "hooks": { "groups": groups } }), &[], || {
        serde_json::to_string_pretty(&json!({ "groups": groups })).expect("groups serialize")
    });
    Ok(())
}

/// `rallo setup hooks [--agent claude|codex]... [--remove] [--print]` (0007).
pub fn run(out: &Output, agents: Vec<Agent>, remove: bool, print: bool) -> CommandResult {
    if print {
        return print_groups(out, agents);
    }

    let home = terminal_command::home_dir()
        .ok_or_else(|| Failure::new(Exit::InvalidInput, "INVALID_INPUT", "$HOME is not set"))?;
    let cli_path = if remove { None } else { Some(installed_cli_path()?) };
    let target_agents = targets(agents, &home);

    struct Target {
        agent: Agent,
        path: PathBuf,
        original: OrderedValue,
        existed: bool,
    }

    let mut loaded = Vec::new();
    let mut invalid_paths = Vec::new();
    for &agent in &target_agents {
        let path = hooks_path(agent, &home);
        match load(&path) {
            Loaded::Existing(value) => loaded.push(Target { agent, path, original: value, existed: true }),
            Loaded::Missing => loaded.push(Target { agent, path, original: default_content(agent), existed: false }),
            Loaded::Invalid => invalid_paths.push(path),
        }
    }
    if !invalid_paths.is_empty() {
        return Err(hooks_config_invalid(&invalid_paths));
    }

    let mut installs = Vec::new();
    let mut lines = Vec::new();
    for target in loaded {
        let mut proposed = target.original.clone();
        let removed = remove_rallo_entries(&mut proposed);
        if !remove {
            append_rallo_groups(&mut proposed, target.agent, cli_path.as_deref().expect("resolved above"));
        }

        let unchanged = proposed == target.original;
        let status = if remove {
            if unchanged { "not_present" } else { "removed" }
        } else if unchanged {
            "already_installed"
        } else if removed > 0 {
            "updated"
        } else {
            "installed"
        };

        let backup_path = if unchanged {
            None
        } else {
            write_target(&target.path, &proposed, target.existed)
                .map_err(|error| Failure::new(Exit::InvalidInput, "HOOKS_SETUP_FAILED", error.to_string()))?
        };

        lines.push(human_line(target.agent, status, &target.path));
        installs.push(json!({
            "agent": target.agent.json_name(),
            "status": status,
            "path": target.path,
            "backup_path": backup_path,
        }));
    }

    out.success(json!({ "hooks": { "targets": installs } }), &[], || lines.join("\n"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_the_quoted_leading_path() {
        assert_eq!(
            extract_cli_path("\"/Applications/Rallo.app/Contents/Helpers/rallo\" agent-event --agent claude"),
            Some("/Applications/Rallo.app/Contents/Helpers/rallo")
        );
        assert_eq!(extract_cli_path("not quoted"), None);
    }

    #[test]
    fn recognises_rallo_commands_by_shape_not_exact_path() {
        assert!(is_rallo_command(
            "\"/Users/x/Applications/Rallo.app/Contents/Helpers/rallo\" agent-event --agent codex"
        ));
        assert!(!is_rallo_command("\"/usr/local/bin/rallo\" agent-event --agent codex"));
        assert!(!is_rallo_command("\"/Applications/Rallo.app/Contents/Helpers/rallo\" note hi"));
    }

    #[test]
    fn remove_drops_only_containers_it_emptied() {
        let mut root = OrderedValue::Object(IndexMap::from([(
            "hooks".to_owned(),
            OrderedValue::Object(IndexMap::from([
                (
                    "PostToolUse".to_owned(),
                    OrderedValue::Array(vec![one_hook_group(
                        "\"/Applications/Rallo.app/Contents/Helpers/rallo\" agent-event --agent claude",
                    )]),
                ),
                // A pre-existing empty array Rallo never touched must survive.
                ("SessionStart".to_owned(), OrderedValue::Array(vec![])),
            ])),
        )]));

        let removed = remove_rallo_entries(&mut root);
        assert_eq!(removed, 1);

        let hooks_obj = root.as_object().unwrap().get("hooks").unwrap().as_object().unwrap();
        assert!(!hooks_obj.contains_key("PostToolUse"), "the now-empty event key was dropped");
        assert!(hooks_obj.contains_key("SessionStart"), "an array Rallo never touched is left alone");
    }

    #[test]
    fn append_then_remove_round_trips_to_the_default() {
        let mut root = default_content(Agent::Claude);
        append_rallo_groups(&mut root, Agent::Claude, Path::new("/Applications/Rallo.app/Contents/Helpers/rallo"));
        assert_ne!(root, default_content(Agent::Claude));
        remove_rallo_entries(&mut root);
        assert_eq!(root, default_content(Agent::Claude), "removing right after installing is a true no-op");
    }
}
