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
//! (`prompt`, `last_assistant_message`) is read, stored, or logged.

use std::io::Read;
use std::path::Path;

use rallo_core::agents::{AgentEvent, AgentKind, AgentState};
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
const CWD_MAX_CHARS: usize = 4096;
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

/// What one recognised hook event does to a session row, before app info
/// (`process_ancestry::terminal_app`) is attached -- that lookup only
/// happens for a `Working`/`Waiting` write (0007), so it is kept out of this
/// pure mapping step.
enum Mapped {
    SetState { state: AgentState, cwd: Option<String>, detail: Option<String> },
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
    let cwd = object.get("cwd").and_then(Value::as_str).map(|cwd| truncate_chars(cwd, CWD_MAX_CHARS));
    let notification_type = object.get("notification_type").and_then(Value::as_str);
    let tool_name = object.get("tool_name").and_then(Value::as_str);

    let waiting = |detail: Option<&str>| Mapped::SetState {
        state: AgentState::Waiting,
        cwd: cwd.clone(),
        detail: detail.map(|detail| truncate_chars(detail, DETAIL_MAX_CHARS)),
    };
    let done = || Mapped::SetState { state: AgentState::Done, cwd: cwd.clone(), detail: None };
    let working = || Mapped::SetState { state: AgentState::Working, cwd: cwd.clone(), detail: None };

    let mapped = match hook_event_name {
        "PermissionRequest" => Some(waiting(tool_name)),
        "Notification" if agent == Agent::Claude => match notification_type {
            Some("permission_prompt" | "elicitation_dialog" | "elicitation_url_dialog" | "agent_needs_input") => {
                Some(waiting(None))
            }
            Some("idle_prompt" | "agent_completed") => Some(done()),
            _ => None,
        },
        "PostToolUse" | "UserPromptSubmit" => Some(working()),
        "Stop" => Some(done()),
        "SessionEnd" | "Interrupt" => Some(Mapped::End),
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
        Mapped::SetState { state, cwd, detail } => {
            let (app_path, app_pid) = if matches!(state, AgentState::Working | AgentState::Waiting) {
                match process_ancestry::terminal_app() {
                    Some((path, pid)) => {
                        (Some(truncate_chars(&path.to_string_lossy(), CWD_MAX_CHARS)), Some(pid.into()))
                    }
                    None => (None, None),
                }
            } else {
                (None, None)
            };
            AgentEvent::SetState { agent: to_core_agent(agent), session_id, state, cwd, detail, app_path, app_pid }
        }
    };

    let data_dir = paths::resolve_data_dir(data_dir_arg).map_err(|error| error.to_string())?;
    let mut store = Store::open(StoreOptions::new(data_dir)).map_err(|error| error.to_string())?;
    let now_ms = store.now_ms();
    let changed = store.record_agent_event(event, now_ms).map_err(|error| error.to_string())?;
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
