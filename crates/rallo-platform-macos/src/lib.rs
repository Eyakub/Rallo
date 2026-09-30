//! Small macOS adapter used by the CLI: locating the installed app, launching
//! it without activation, and posting change hints. Kept outside the core.

pub mod change_signal;
pub mod launch;
pub mod process_ancestry;
pub mod terminal_command;
pub mod update;
