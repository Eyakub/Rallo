//! `rallo agent-event --agent claude|codex` (0007): reads one hook payload
//! from stdin and records the mapped state. **Always exits 0 and never
//! writes to stdout** -- Claude Code adds a nonzero-exit hook's stderr to the
//! model's context and can block `Stop`/`UserPromptSubmit`, so a failure here
//! must never look like a problem to the agent. Every failure (bad JSON, a
//! missing/invalid `session_id`, a busy or unavailable store) is one line on
//! stderr instead.
//!
//! Only `hook_event_name`, `session_id`, `cwd`, `notification_type`, and
//! `tool_name` are ever read from the payload: no prompt or model text
//! (`prompt`, `last_assistant_message`) is read, stored, or logged. Of `cwd`
//! only the last two folders are kept (0009).

use std::io::Read;
use std::path::Path;

use rallo_core::agents::{AgentEvent, AgentKind, AgentLocation, AgentProcessId, AgentState};
use rallo_core::shared::signal;
use rallo_core::storage::paths;
use rallo_core::{Store, StoreOptions};
use rallo_platform_macos::{change_signal, process_ancestry};
use serde_json::Value;

use crate::skill::Agent;

/// Hard ceiling on the hook payload: bounds memory regardless of what a
/// misbehaving agent sends. A truncated payload simply fails to parse as
/// JSON, landing on the same "invalid JSON" stderr line as any other bad
/// input, rather than needing its own error case.
const STDIN_CAP_BYTES: u64 = 1024 * 1024;
const PATH_MAX_CHARS: usize = 4096;
const PLACE_MAX_CHARS: usize = 300;
const DETAIL_MAX_CHARS: usize = 60;
const SESSION_ID_MAX_CHARS: usize = 200;

fn to_core_agent(agent: Agent) -> AgentKind {
    match agent {
        Agent::Claude => AgentKind::Claude,
        Agent::Codex => AgentKind::Codex,
    }
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

/// Where the agent runs, for the panel: the last two path components of
/// `cwd` ("haat/raw" and "circuit/raw" stay apart), "~" for the home folder.
fn place(cwd: &str, home: Option<&Path>) -> Option<String> {
    let cwd = Path::new(cwd);
    if home.is_some_and(|home| home == cwd) {
        return Some("~".to_owned());
    }
    let parts: Vec<_> = cwd.iter().filter(|part| *part != "/").map(|part| part.to_string_lossy()).collect();
    let tail = parts[parts.len().saturating_sub(2)..].join("/");
    (!tail.is_empty()).then(|| truncate_chars(&tail, PLACE_MAX_CHARS))
}

/// A terminal target Rallo can bring forward exactly (0009): the cmux
/// workspace and panel the agent runs in, else its controlling terminal.
fn focus(cmux_workspace: Option<&str>, cmux_panel: Option<&str>, tty: Option<&str>) -> Option<String> {
    let id =
        |value: &str| (1..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    match (cmux_workspace, cmux_panel) {
        (Some(workspace), Some(panel)) if id(workspace) && id(panel) => Some(format!("cmux:{workspace}:{panel}")),
        _ => tty.filter(|tty| tty.starts_with("/dev/tty") && tty.len() <= 64).map(|tty| format!("tty:{tty}")),
    }
}

/// What one recognised hook event does to a session row, before the agent's
/// location (process, terminal app, focus) is attached -- those lookups only
/// happen for a `Working`/`Waiting` write, so they are kept out of this pure
/// mapping step.
enum Mapped {
    SetState { state: AgentState, place: Option<String>, detail: Option<String> },
    End,
}

/// Maps a raw hook payload to `(session_id, Mapped)` per 0007's event table.
/// `Ok(None)` covers every "ignore" case documented there: a
/// `hook_event_name` this build doesn't map (including a Codex payload's
/// unrelated `Notification`, which the table reserves for Claude Code only),
/// or one absent altogether. Only a malformed payload -- not valid JSON, not
/// a JSON object, or missing/invalid `session_id` -- is an `Err`.
fn map_event(agent: Agent, payload: &[u8]) -> Result<Option<(String, Mapped)>, &'static str> {
    let value: Value = serde_json::from_slice(payload).map_err(|_| "invalid JSON on stdin")?;
    let object = value.as_object().ok_or("payload is not a JSON object")?;

    let session_id = object.get("session_id").and_then(Value::as_str).ok_or("missing session_id")?;
    if session_id.is_empty() || session_id.chars().count() > SESSION_ID_MAX_CHARS {
        return Err("session_id is empty or too long");
    }

    let Some(hook_event_name) = object.get("hook_event_name").and_then(Value::as_str) else {
        return Ok(None);
    };
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let place = object.get("cwd").and_then(Value::as_str).and_then(|cwd| place(cwd, home.as_deref()));
    let notification_type = object.get("notification_type").and_then(Value::as_str);
    let tool_name = object.get("tool_name").and_then(Value::as_str);

    let waiting = |detail: Option<&str>| Mapped::SetState {
        state: AgentState::Waiting,
        place: place.clone(),
        detail: detail.map(|detail| truncate_chars(detail, DETAIL_MAX_CHARS)),
    };
    let working = || Mapped::SetState { state: AgentState::Working, place: place.clone(), detail: None };

    let mapped = match hook_event_name {
        "PermissionRequest" => Some(waiting(tool_name)),
        "Notification" if agent == Agent::Claude => match notification_type {
            Some("permission_prompt" | "elicitation_dialog" | "elicitation_url_dialog" | "agent_needs_input") => {
                Some(waiting(None))
            }
            // A finished turn isn't a question for the user: the row goes, as
            // on SessionEnd, so only agents waiting on an answer are listed
            // (0007, amended 2026-10-01).
            Some("idle_prompt" | "agent_completed") => Some(Mapped::End),
            _ => None,
        },
        "PostToolUse" | "UserPromptSubmit" => Some(working()),
        "Stop" | "SessionEnd" | "Interrupt" => Some(Mapped::End),
        _ => None,
    };
    Ok(mapped.map(|mapped| (session_id.to_owned(), mapped)))
}

fn read_stdin_capped() -> Vec<u8> {
    let mut bytes = Vec::new();
    // Errors (e.g. no stdin at all) leave `bytes` as whatever was read so
    // far, which then simply fails to parse below -- never a reason to block
    // or print to stdout.
    let _ = std::io::stdin().lock().take(STDIN_CAP_BYTES).read_to_end(&mut bytes);
    bytes
}

fn apply(data_dir_arg: Option<&Path>, agent: Agent, session_id: String, mapped: Mapped) -> Result<(), String> {
    let event = match mapped {
        Mapped::End => AgentEvent::End { agent: to_core_agent(agent), session_id },
        Mapped::SetState { state, place, detail } => {
            let app = process_ancestry::terminal_app();
            let process = process_ancestry::agent_process();
            let env = |name| std::env::var(name).ok();
            let location = AgentLocation {
                app_path: app.as_ref().map(|(path, _)| truncate_chars(&path.to_string_lossy(), PATH_MAX_CHARS)),
                app_pid: app.map(|(_, pid)| pid.into()),
                focus: focus(
                    env("CMUX_WORKSPACE_ID").as_deref(),
                    env("CMUX_PANEL_ID").as_deref(),
                    process.as_ref().and_then(|process| process.tty.as_deref()),
                ),
                process: process
                    .map(|process| AgentProcessId { pid: process.pid.into(), started_us: process.started_us }),
            };
            AgentEvent::SetState { agent: to_core_agent(agent), session_id, state, place, detail, location }
        }
    };

    let data_dir = paths::resolve_data_dir(data_dir_arg).map_err(|error| error.to_string())?;
    let mut store = Store::open(StoreOptions::new(data_dir)).map_err(|error| error.to_string())?;
    let now_ms = store.now_ms();
    let changed = store
        .record_agent_event(event, now_ms, &|p| process_ancestry::is_alive(p.pid, p.started_us))
        .map_err(|error| error.to_string())?;
    if changed {
        change_signal::post(&signal::change_signal_name(store.data_dir()));
    }
    Ok(())
}

/// Never returns an error: every failure is already reported to stderr here.
pub fn run(data_dir_arg: Option<&Path>, agent: Agent) {
    let payload = read_stdin_capped();
    match map_event(agent, &payload) {
        Err(reason) => eprintln!("agent-event: {reason}"),
        Ok(None) => {}
        Ok(Some((session_id, mapped))) => {
            if let Err(error) = apply(data_dir_arg, agent, session_id, mapped) {
                eprintln!("agent-event: {error}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn place_keeps_the_last_two_folders() {
        let home = Some(Path::new("/Users/me"));
        assert_eq!(place("/Users/me/code/haat/raw", home).as_deref(), Some("haat/raw"));
        assert_eq!(place("/Users/me/code/haat/raw/", home).as_deref(), Some("haat/raw"));
        assert_eq!(place("/Users/me", home).as_deref(), Some("~"));
        assert_eq!(place("/tmp", home).as_deref(), Some("tmp"));
        assert_eq!(place("/", home), None);
        assert_eq!(place("", home), None);
    }

    #[test]
    fn focus_prefers_a_valid_cmux_pane_then_the_tty() {
        let ws = "A8E6AFDC-7521-43FE-95F1-CEE1DB2B0B8F";
        assert_eq!(focus(Some(ws), Some("P-1"), Some("/dev/ttys003")), Some(format!("cmux:{ws}:P-1")));
        assert_eq!(focus(None, None, Some("/dev/ttys003")).as_deref(), Some("tty:/dev/ttys003"));
        assert_eq!(focus(Some("bad;id"), Some("P"), Some("/dev/ttys003")).as_deref(), Some("tty:/dev/ttys003"));
        assert_eq!(focus(Some(ws), None, None), None);
        assert_eq!(focus(None, None, Some("/etc/passwd")), None);
    }
}
