use std::path::PathBuf;

use clap::{Parser, Subcommand};
use rallo_core::items::service::DEFAULT_PAGE_SIZE;

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
        /// Idempotency key: retrying with the same key and inputs replays the original result.
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
    },
    /// Save a one-time reminder.
    Remind {
        /// Note text. Use --stdin for arbitrary text.
        #[arg(required_unless_present = "stdin", conflicts_with = "stdin")]
        text: Option<String>,
        /// Read the note text from standard input (one trailing newline is dropped).
        #[arg(long)]
        stdin: bool,
        /// Relative duration such as "20m" or "1h30m". Exactly one of --in/--at is required.
        #[arg(long = "in", value_name = "DURATION", conflicts_with = "at", required_unless_present = "at")]
        in_: Option<String>,
        /// Absolute RFC 3339 deadline with an explicit offset, e.g. "2026-10-01T15:00:00+06:00".
        #[arg(long, value_name = "RFC3339")]
        at: Option<String>,
        /// Idempotency key: retrying a relative "--in" duration must not move the deadline again.
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
    },
    /// List notes (open and nondeleted by default).
    List {
        /// Open and done items, excluding deleted.
        #[arg(long, conflicts_with_all = ["deleted", "due"])]
        all: bool,
        /// Deleted items only.
        #[arg(long, conflicts_with_all = ["all", "due"])]
        deleted: bool,
        /// Open items with an active reminder whose deadline has passed.
        #[arg(long, conflicts_with_all = ["all", "deleted"])]
        due: bool,
        /// Page size (1-200).
        #[arg(long, default_value_t = DEFAULT_PAGE_SIZE)]
        limit: u32,
        /// Opaque cursor from a previous page's next_cursor.
        #[arg(long)]
        cursor: Option<String>,
    },
    /// Inspect one item by full ID or unique prefix.
    Get { id: String },
    /// Literal text search (not SQL/regex).
    Search {
        text: String,
        /// Match the entire normalized text instead of a substring.
        #[arg(long)]
        exact: bool,
        /// Include soft-deleted items in the results.
        #[arg(long)]
        include_deleted: bool,
        /// Page size (1-200).
        #[arg(long, default_value_t = DEFAULT_PAGE_SIZE)]
        limit: u32,
        /// Opaque cursor from a previous page's next_cursor.
        #[arg(long)]
        cursor: Option<String>,
    },
    /// Replace an item's text.
    Edit {
        id: String,
        #[arg(long)]
        text: String,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        /// Fail with a conflict unless the item is currently at this revision.
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Mark an item done.
    Done {
        id: String,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Reopen a done item. Never re-enables an old reminder.
    Reopen {
        id: String,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Restore a soft-deleted item. Never re-enables its old reminder.
    Restore {
        id: String,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Reschedule an item's reminder to a new deadline (creates one if it has none).
    Reschedule {
        id: String,
        #[arg(long = "in", value_name = "DURATION", conflicts_with = "at", required_unless_present = "at")]
        in_: Option<String>,
        #[arg(long, value_name = "RFC3339")]
        at: Option<String>,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Push an item's existing reminder out by a relative duration.
    Snooze {
        id: String,
        #[arg(long = "in", value_name = "DURATION")]
        duration: String,
        /// Retrying with the same key must not move the deadline again.
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Acknowledge an item's active reminder, clearing due-attention state.
    Acknowledge {
        id: String,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Cancel an item's active reminder without completing the item.
    CancelReminder {
        id: String,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Soft-delete an item by ID or by its exact, unique note text.
    Delete {
        /// Full ID or unique prefix. Exactly one of ID / --text is required.
        #[arg(required_unless_present = "text", conflicts_with = "text")]
        id: Option<String>,
        /// Exact stored text (normalized: trimmed, case-folded, NFC) among nondeleted items.
        #[arg(long)]
        text: Option<String>,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        /// Only valid alongside an ID selector.
        #[arg(long, value_name = "N", conflicts_with = "text")]
        if_revision: Option<i64>,
    },
    /// Show the pet (launches the app if needed, without taking focus).
    Show {
        /// Move the pet back to its default position.
        #[arg(long)]
        reset_position: bool,
    },
    /// Hide the pet. Persists across restarts; does not quit the app.
    Hide,
    /// Report app/storage/pet status, or one item's scheduling/cancellation detail.
    Status {
        /// Full ID or unique prefix. Omit for the app/storage overview.
        id: Option<String>,
    },
}
