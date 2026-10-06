//! Small macOS adapter used by the CLI and, through `rallo-ffi`, the app:
//! locating the installed app, launching it without activation, posting change
//! hints, and converting local wall-clock time to and from instants
//! (`local_time`, 0016). Kept outside the core.

pub mod change_signal;
pub mod launch;
pub mod local_time;
pub mod process_ancestry;
pub mod terminal_command;
pub mod update;
