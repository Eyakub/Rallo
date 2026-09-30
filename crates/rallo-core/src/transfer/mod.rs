//! Export/import (build plan §10, decision 0004): a lossless versioned JSON
//! backup and a spreadsheet-friendly CSV. See
//! `docs/decisions/0004-export-import-formats.md` for the format shapes,
//! validation rules, and classification (`new`/`identical`/`conflict`)
//! semantics.

pub mod export;
mod formula_guard;
pub mod import;

pub use export::{ExportFormat, ExportSummary};
pub use import::{ImportConflictRecord, ImportReport, MAX_IMPORT_BYTES};
