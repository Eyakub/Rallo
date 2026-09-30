use std::io::{self, Write};
use std::process::ExitCode;

use rallo_core::{CoreError, ErrorCode};
use serde_json::{Map, Value, json};

/// Process exit codes; part of the CLI contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Exit {
    Success = 0,
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

/// A command failure before (or instead of) any commit.
#[derive(Debug)]
pub struct Failure {
    pub exit: Exit,
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    pub fn new(exit: Exit, code: &'static str, message: impl Into<String>) -> Self {
        Self { exit, code, message: message.into() }
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
        Self::new(exit, error.code().as_str(), error.to_string())
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
            let mut envelope = envelope(false);
            envelope.insert("error".into(), json!({ "code": failure.code, "message": failure.message }));
            write_stdout(&Value::Object(envelope).to_string());
        } else {
            eprintln!("error: {}", sanitize_line(&failure.message));
        }
        failure.exit.into()
    }
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
