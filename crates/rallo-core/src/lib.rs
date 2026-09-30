//! Rallo core: domain rules, persistence, reminder intent, and the pet reducer.
//!
//! This crate is a library, not a server. The CLI and the macOS app are separate
//! processes that share one SQLite database through it. It must never depend on
//! AppKit or perform network calls.

pub mod items;
pub mod preferences;
pub mod reminders;
pub mod shared;
pub mod storage;
pub mod transfer;

pub use shared::errors::{CoreError, ErrorCode};
pub use storage::database::{Store, StoreOptions};

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Version of the machine-readable JSON contract (`schema_version` in CLI output).
pub const JSON_CONTRACT_VERSION: u32 = 1;
