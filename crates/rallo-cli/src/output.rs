use std::io::{self, Write};
use std::process::ExitCode;

use rallo_core::items::ItemView;
use rallo_core::shared::errors::ConflictDetail;
use rallo_core::{CoreError, ErrorCode};
use serde_json::{Map, Value, json};

use crate::local_time::format_local;

/// Process exit codes; part of the CLI contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Exit {
    Success = 0,
    /// `rallo doctor` found at least one `problem`-level check. Not used by
    /// any other command.
    DoctorProblems = 1,
    InvalidInput = 2,
    NotFound = 3,
    Conflict = 4,
    Storage = 5,
    Platform = 6,
    Incompatible = 7,
}

impl From<Exit> for ExitCode {
    fn from(exit: Exit) -> Self {
        ExitCode::from(exit as u8)
    }
}

/// A command failure before (or instead of) any commit. `detail` is boxed:
/// `ConflictDetail::Current` embeds a full `ItemView`, and this type is
/// carried through every fallible command's `Result`.
#[derive(Debug)]
pub struct Failure {
    pub exit: Exit,
    pub code: &'static str,
    pub message: String,
    pub detail: Option<Box<ConflictDetail>>,
}

impl Failure {
    pub fn new(exit: Exit, code: &'static str, message: impl Into<String>) -> Self {
        Self { exit, code, message: message.into(), detail: None }
    }
}

impl From<CoreError> for Failure {
    fn from(error: CoreError) -> Self {
        let exit = match &error {
            CoreError::InvalidInput { .. } => Exit::InvalidInput,
            CoreError::NotFound { .. } => Exit::NotFound,
            CoreError::Conflict { .. } => Exit::Conflict,
            CoreError::Storage { .. } => Exit::Storage,
            CoreError::IncompatibleSchema { .. } => Exit::Incompatible,
        };
        let code = error.code().as_str();
        let detail = error.detail().cloned().map(Box::new);
        let mut message = error.to_string();
        // EACCES/EPERM on the store: most often an agent's sandbox, which
        // can't see ~/Library. Said only here, when it has happened, so agents
        // don't assume it up front.
        if matches!(error, CoreError::Storage { .. })
            && (message.contains("(os error 13)") || message.contains("(os error 1)"))
        {
            message.push_str(
                ". If an agent's sandbox is running this command, Rallo's data is outside it: let `rallo` run \
                 outside the sandbox (for Codex, `rallo setup skill` adds rules that allow it)",
            );
        }
        Self { exit, code, message, detail }
    }
}

impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Self {
        Self::new(Exit::InvalidInput, ErrorCode::InvalidInput.as_str(), format!("could not read input: {error}"))
    }
}

pub struct Output {
    pub json: bool,
}

impl Output {
    /// Writes a success document: `fields` merged into the JSON envelope, or
    /// the human text otherwise.
    pub fn success(&self, fields: Value, warnings: &[String], human: impl FnOnce() -> String) {
        if self.json {
            let mut envelope = envelope(true);
            if let Value::Object(fields) = fields {
                envelope.extend(fields);
            }
            envelope.insert("warnings".into(), json!(warnings));
            write_stdout(&Value::Object(envelope).to_string());
        } else {
            write_stdout(&human());
            for warning in warnings {
                eprintln!("warning: {}", sanitize_line(warning));
            }
        }
    }

    pub fn failure(&self, failure: &Failure) -> ExitCode {
        if self.json {
            let mut error = Map::new();
            error.insert("code".into(), json!(failure.code));
            error.insert("message".into(), json!(failure.message));
            if let Some(detail) = &failure.detail {
                error.insert("detail".into(), serde_json::to_value(detail).expect("ConflictDetail serializes"));
            }
            let mut envelope = envelope(false);
            envelope.insert("error".into(), Value::Object(error));
            write_stdout(&Value::Object(envelope).to_string());
        } else {
            eprintln!("error: {}", sanitize_line(&failure.message));
            if let Some(detail) = &failure.detail {
                render_detail_human(detail);
            }
        }
        failure.exit.into()
    }
}

/// Human-readable rendering of a conflict's structured detail (0003 §11):
/// ambiguity candidates, the current snapshot on a stale revision, or the
/// active/limit counts at capacity. Always to stderr; nothing was mutated.
fn render_detail_human(detail: &ConflictDetail) {
    match detail {
        ConflictDetail::Candidates { total, candidates } => {
            for view in candidates {
                eprintln!("  {}", candidate_line(view));
            }
            if *total as usize > candidates.len() {
                eprintln!("{total} matches; showing {}", candidates.len());
            }
        }
        ConflictDetail::Current { item } => {
            eprintln!(
                "current: {}  revision {}  “{}”",
                item.item.status.as_str(),
                item.item.revision,
                preview(&item.item.text, 100),
            );
            eprintln!("Nothing changed.");
        }
        ConflictDetail::Capacity { limit, active } => {
            eprintln!("{active} of {limit} reminders are already active.");
        }
        ConflictDetail::ImportConflicts { total, conflicts } => {
            for conflict in conflicts {
                let location = match (conflict.line, conflict.index) {
                    (Some(line), _) => format!("line {line}"),
                    (None, Some(index)) => format!("record {index}"),
                    (None, None) => "record".to_owned(),
                };
                let id = conflict.id.map(|id| format!(" ({id})")).unwrap_or_default();
                eprintln!("  {location}{id}: {}", conflict.reason);
            }
            if *total as usize > conflicts.len() {
                eprintln!("{total} conflicts; showing {}", conflicts.len());
            }
            eprintln!("Nothing was imported.");
        }
    }
}

/// One candidate line distinguishing an ambiguous match without requiring the
/// reader to memorize IDs: display ID, open/done, creation time, reminder
/// time if any, and a text preview.
fn candidate_line(view: &ItemView) -> String {
    let reminder = view
        .reminder
        .as_ref()
        .map(|reminder| format!("  reminder {}", format_local(reminder.deadline_ms)))
        .unwrap_or_default();
    format!(
        "{}  {}  created {}{reminder}  “{}”",
        view.display_id,
        view.item.status.as_str(),
        format_local(view.item.created_at_ms),
        preview(&view.item.text, 60),
    )
}

fn envelope(ok: bool) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert("schema_version".into(), json!(rallo_core::JSON_CONTRACT_VERSION));
    map.insert("ok".into(), json!(ok));
    map
}

fn write_stdout(text: &str) {
    let mut stdout = io::stdout().lock();
    // SIGPIPE is restored to its default in main, so a closed pipe ends the
    // process the ordinary way; other write errors have nowhere to go.
    let _ = writeln!(stdout, "{text}");
}

/// Renders stored text safely on a terminal: control characters and bidi
/// overrides become U+FFFD and line breaks are flattened. JSON output is
/// never sanitised; serde escapes it losslessly.
pub fn sanitize_line(text: &str) -> String {
    text.trim()
        .chars()
        .map(|c| match c {
            '\n' | '\r' | '\t' => ' ',
            c if c.is_control() => '\u{fffd}',
            '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' => '\u{fffd}',
            c => c,
        })
        .collect()
}

/// One-line human preview of note text.
pub fn preview(text: &str, max_chars: usize) -> String {
    let line = sanitize_line(text);
    if line.chars().count() <= max_chars {
        line
    } else {
        let mut cut: String = line.chars().take(max_chars.saturating_sub(1)).collect();
        cut.push('…');
        cut
    }
}
