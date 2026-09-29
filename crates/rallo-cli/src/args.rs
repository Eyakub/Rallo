use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "rallo",
    about = "Capture notes and one-time reminders; Rallo keeps them visible.",
    disable_version_flag = true
)]
pub struct Cli {
    /// Emit machine-readable JSON on stdout (diagnostics stay on stderr).
    #[arg(long, global = true)]
    pub json: bool,

    /// Use an explicit data directory instead of the default (for tests and development).
    #[arg(long, global = true, value_name = "DIR", env = "RALLO_DATA_DIR", hide_env_values = true)]
    pub data_dir: Option<PathBuf>,

    /// Print CLI, core, and schema versions.
    #[arg(short = 'V', long)]
    pub version: bool,

    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Save a note.
    Note {
        /// Note text. Use --stdin for arbitrary text.
        #[arg(required_unless_present = "stdin", conflicts_with = "stdin")]
        text: Option<String>,
        /// Read the note text from standard input (one trailing newline is dropped).
        #[arg(long)]
        stdin: bool,
    },
    /// List open notes.
    List,
    /// Show the pet (launches the app if needed, without taking focus).
    Show {
        /// Move the pet back to its default position.
        #[arg(long)]
        reset_position: bool,
    },
    /// Hide the pet. Persists across restarts; does not quit the app.
    Hide,
    /// Report app, storage, and pet status.
    Status,
}
