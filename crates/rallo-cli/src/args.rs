use std::path::PathBuf;

use clap::{Parser, Subcommand};
use rallo_core::items::service::DEFAULT_PAGE_SIZE;

use crate::skill::Agent;

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
        #[arg(required_unless_present_any = ["stdin", "images"], conflicts_with = "stdin")]
        text: Option<String>,
        /// Read the note text from standard input (one trailing newline is dropped).
        #[arg(long)]
        stdin: bool,
        /// Attach an image file (PNG, JPEG, HEIC, GIF or WebP; 10 MB each, up to 10). Rallo keeps its own copy.
        #[arg(long = "image", value_name = "PATH")]
        images: Vec<PathBuf>,
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
        /// When: RFC 3339 with an explicit offset ("2026-10-01T15:00:00+06:00") or a
        /// phrase such as "fri 5pm", "tomorrow 9am", "oct 20", "in 2 hours".
        #[arg(long, value_name = "WHEN")]
        at: Option<String>,
        /// Attach an image file (PNG, JPEG, HEIC, GIF or WebP; 10 MB each, up to 10). Rallo keeps its own copy.
        #[arg(long = "image", value_name = "PATH")]
        images: Vec<PathBuf>,
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
    /// Add images to a note (PNG, JPEG, HEIC, GIF or WebP; 10 MB each, 10 per note).
    Attach {
        /// Full ID or unique prefix.
        id: String,
        /// Image files. Rallo keeps its own copies.
        #[arg(required = true, value_name = "PATH")]
        paths: Vec<PathBuf>,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
        #[arg(long, value_name = "N")]
        if_revision: Option<i64>,
    },
    /// Remove one image from a note (IDs are in `rallo get ID --json`).
    Detach {
        /// Full ID or unique prefix.
        id: String,
        image_id: String,
        #[arg(long, value_name = "KEY")]
        request_id: Option<String>,
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
        /// When: RFC 3339 with an explicit offset ("2026-10-01T15:00:00+06:00") or a
        /// phrase such as "fri 5pm", "tomorrow 9am", "oct 20", "in 2 hours".
        #[arg(long, value_name = "WHEN")]
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
    /// Export notes and reminders. JSON is a lossless backup; CSV is
    /// spreadsheet-friendly but excludes deleted items and some reminder detail.
    Export {
        /// Destination path, or "-" for stdout.
        #[arg(long, value_name = "PATH")]
        output: String,
        /// Defaults from the output extension: `.csv` is CSV, `.zip` is a zip with images, anything else is JSON.
        #[arg(long, value_enum)]
        format: Option<ExportFormatArg>,
        /// Overwrite an existing file at --output.
        #[arg(long)]
        force: bool,
    },
    /// Import notes and reminders from a previous export.
    Import {
        /// Source path, or "-" for stdin.
        #[arg(long, value_name = "PATH")]
        file: String,
        /// Validate and report without writing anything.
        #[arg(long)]
        dry_run: bool,
    },
    /// Setup and repair helpers (not notes commands); never starts the app.
    Setup {
        #[command(subcommand)]
        command: SetupCommand,
    },
    /// Read-only health report: storage, permissions, the installed app, the
    /// terminal command, and pending reminder work. Never starts, signals, or
    /// migrates anything. Exits 1 if any check is a `problem`.
    Doctor,
    /// Write a consistent snapshot of the database using SQLite's online
    /// backup API. Never starts the app; works while it is running.
    Backup {
        /// Destination path. Defaults to `<data dir>/backups/manual-<timestamp>.sqlite3`.
        #[arg(long, value_name = "PATH")]
        output: Option<String>,
        /// Overwrite an existing file at --output.
        #[arg(long)]
        force: bool,
    },
    /// Check for and install the latest release from GitHub Releases. The
    /// only command that uses the network, and only when run directly --
    /// never automatically, never in the background.
    Update {
        /// Report whether an update is available without downloading or installing it.
        #[arg(long)]
        check: bool,
    },
    /// Remove Rallo from this Mac: the app, its terminal command, agent hooks and skill, Open at Login,
    /// scheduled reminders, the ClickUp token, and voice API keys. Keeps your notes unless --purge.
    Uninstall {
        /// Also delete your notes and settings, after saving a final zip export (with images) to ~/Downloads.
        #[arg(long)]
        purge: bool,
        /// Don't ask for confirmation.
        #[arg(long)]
        yes: bool,
    },
    /// Records one Claude Code/Codex/Grok/Gemini CLI hook payload from stdin (0007). Not
    /// meant to be run by hand: `rallo setup hooks` wires this up. Always
    /// exits 0 and writes nothing to stdout.
    #[command(hide = true)]
    AgentEvent {
        #[arg(long)]
        agent: Agent,
    },
    /// Lists current Claude Code/Codex/Grok/Gemini CLI sessions the pet is tracking (0007).
    Agents {
        #[command(subcommand)]
        command: Option<AgentsCommand>,
    },
}

#[derive(Debug, Subcommand)]
pub enum AgentsCommand {
    /// Removes tracked sessions.
    Clear {
        /// Only sessions for this agent.
        #[arg(long = "agent", value_enum)]
        agent: Option<Agent>,
        /// Only this session id.
        #[arg(long)]
        session: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
pub enum SetupCommand {
    /// Link the CLI inside this installed app onto PATH as `rallo` (spec
    /// §10); repairs a link left by a moved app and reports an existing,
    /// correct link idempotently. Never replaces a `rallo` that isn't
    /// Rallo's own link, and never starts the app.
    Terminal,
    /// Install the agent skill for this version for every detected agent
    /// (Claude Code, Cursor, Codex, Grok, and Gemini CLI; Codex also gets a `rallo.rules`
    /// execpolicy file); updates an older copy. Never replaces a skill, or
    /// rules file, that isn't Rallo's.
    Skill {
        /// Write the skill to stdout instead, for agents that take
        /// instructions another way. Ignores `--agent`; installs nothing.
        #[arg(long)]
        print: bool,
        /// Install only for these agents (repeatable). Creates the agent's
        /// directories even if it wasn't detected. Default: every detected
        /// agent, or Claude Code/Cursor if none is detected.
        #[arg(long = "agent", value_enum)]
        agents: Vec<Agent>,
    },
    /// Installs the `agent-event` hook command for every detected agent
    /// (0007): merges into Claude Code's `~/.claude/settings.json` and/or
    /// Codex's `$CODEX_HOME/hooks.json`, and/or Grok's
    /// `$GROK_HOME/hooks/rallo.json`, and/or Gemini CLI's
    /// `~/.gemini/settings.json`. Never replaces a hook entry that isn't
    /// Rallo's own.
    Hooks {
        /// Install only for these agents (repeatable). Default: every
        /// detected agent, or Claude Code if none is detected.
        #[arg(long = "agent", value_enum)]
        agents: Vec<Agent>,
        /// Remove Rallo's hook entries instead of installing them.
        #[arg(long, conflicts_with = "print")]
        remove: bool,
        /// Print the hook entries this would add per agent instead of
        /// writing anything.
        #[arg(long)]
        print: bool,
    },
}

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum ExportFormatArg {
    Json,
    Csv,
    Zip,
}
