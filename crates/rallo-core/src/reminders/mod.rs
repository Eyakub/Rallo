pub mod model;
pub(crate) mod repository;
pub mod service;
pub mod time;

pub use model::{CancellationStatus, InputKind, Reminder, ReminderState, SchedulingStatus};
pub use time::TimeSpec;

/// Maximum number of simultaneously active (`enabled = 1`) reminders (0003
/// §4). Enforced inside the write transaction that is about to enable one
/// that is not already active.
pub const MAX_ACTIVE_REMINDERS: u32 = 32;
