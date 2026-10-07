use serde::Serialize;

use crate::items::model::ItemView;
use crate::transfer::import::ImportConflictRecord;

/// Stable machine-readable error codes. Part of the CLI JSON contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    InvalidInput,
    TextEmpty,
    TextTooLong,
    InvalidId,
    ItemNotFound,
    StorageUnavailable,
    StorageBusy,
    IncompatibleSchema,
    InvalidTime,
    AmbiguousId,
    AmbiguousItem,
    RevisionConflict,
    RequestIdConflict,
    ItemDeleted,
    ItemNotOpen,
    NoReminder,
    ReminderCapacityReached,
    InvalidImport,
    ImportConflict,
    FileExists,
    ImageUnsupported,
    ImageTooLarge,
    TooManyImages,
    ImageUnreadable,
    ImageNotFound,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidInput => "INVALID_INPUT",
            Self::TextEmpty => "TEXT_EMPTY",
            Self::TextTooLong => "TEXT_TOO_LONG",
            Self::InvalidId => "INVALID_ID",
            Self::ItemNotFound => "ITEM_NOT_FOUND",
            Self::StorageUnavailable => "STORAGE_UNAVAILABLE",
            Self::StorageBusy => "STORAGE_BUSY",
            Self::IncompatibleSchema => "INCOMPATIBLE_SCHEMA",
            Self::InvalidTime => "INVALID_TIME",
            Self::AmbiguousId => "AMBIGUOUS_ID",
            Self::AmbiguousItem => "AMBIGUOUS_ITEM",
            Self::RevisionConflict => "REVISION_CONFLICT",
            Self::RequestIdConflict => "REQUEST_ID_CONFLICT",
            Self::ItemDeleted => "ITEM_DELETED",
            Self::ItemNotOpen => "ITEM_NOT_OPEN",
            Self::NoReminder => "NO_REMINDER",
            Self::ReminderCapacityReached => "REMINDER_CAPACITY_REACHED",
            Self::InvalidImport => "INVALID_IMPORT",
            Self::ImportConflict => "IMPORT_CONFLICT",
            Self::FileExists => "FILE_EXISTS",
            Self::ImageUnsupported => "IMAGE_UNSUPPORTED",
            Self::ImageTooLarge => "IMAGE_TOO_LARGE",
            Self::TooManyImages => "TOO_MANY_IMAGES",
            Self::ImageUnreadable => "IMAGE_UNREADABLE",
            Self::ImageNotFound => "IMAGE_NOT_FOUND",
        }
    }
}

/// Structured payload for `CoreError::Conflict`, serialized as the error's
/// flat `detail` object (0003 §11): `{total, candidates}`, `{current}`, or
/// `{limit, active}`. Never includes note text.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
// `Current { item: ItemView }` is specified verbatim by 0003; boxing it would
// change the public field type for a size difference that only matters if
// conflicts are constructed in a hot loop, which they are not.
#[allow(clippy::large_enum_variant)]
pub enum ConflictDetail {
    Candidates {
        total: u64,
        candidates: Vec<ItemView>,
    },
    Current {
        #[serde(rename = "current")]
        item: ItemView,
    },
    Capacity {
        limit: u32,
        active: u32,
    },
    /// `IMPORT_CONFLICT` (0004): a bounded list of records whose id matches an
    /// existing item with different content. `total` may exceed
    /// `conflicts.len()`; never includes note text.
    ImportConflicts {
        total: u64,
        conflicts: Vec<ImportConflictRecord>,
    },
}

/// Errors surfaced across the CLI and FFI boundaries.
///
/// Messages never contain note text: they may reach logs and diagnostics.
#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("{message}")]
    InvalidInput { code: ErrorCode, message: String },
    #[error("{message}")]
    NotFound { code: ErrorCode, message: String },
    #[error("{message}")]
    Storage { code: ErrorCode, message: String },
    /// Ambiguous selection, a stale revision, a request-id collision, or a
    /// precondition failure (deleted/not-open/no-reminder/at-capacity).
    #[error("{message}")]
    Conflict { code: ErrorCode, message: String, detail: Option<Box<ConflictDetail>> },
    #[error("database schema version {found} is newer than this build supports ({supported})")]
    IncompatibleSchema { found: u32, supported: u32 },
}

impl CoreError {
    pub fn code(&self) -> ErrorCode {
        match self {
            Self::InvalidInput { code, .. }
            | Self::NotFound { code, .. }
            | Self::Storage { code, .. }
            | Self::Conflict { code, .. } => *code,
            Self::IncompatibleSchema { .. } => ErrorCode::IncompatibleSchema,
        }
    }

    /// The structured detail carried by a `Conflict`, if any.
    pub fn detail(&self) -> Option<&ConflictDetail> {
        match self {
            Self::Conflict { detail, .. } => detail.as_deref(),
            _ => None,
        }
    }

    pub(crate) fn invalid(code: ErrorCode, message: impl Into<String>) -> Self {
        Self::InvalidInput { code, message: message.into() }
    }

    pub(crate) fn not_found(code: ErrorCode, message: impl Into<String>) -> Self {
        Self::NotFound { code, message: message.into() }
    }

    pub(crate) fn storage(message: impl Into<String>) -> Self {
        Self::Storage { code: ErrorCode::StorageUnavailable, message: message.into() }
    }

    pub(crate) fn conflict(code: ErrorCode, message: impl Into<String>) -> Self {
        Self::Conflict { code, message: message.into(), detail: None }
    }

    pub(crate) fn conflict_detail(code: ErrorCode, message: impl Into<String>, detail: ConflictDetail) -> Self {
        Self::Conflict { code, message: message.into(), detail: Some(Box::new(detail)) }
    }
}

impl From<rusqlite::Error> for CoreError {
    fn from(error: rusqlite::Error) -> Self {
        let busy = matches!(
            error.sqlite_error_code(),
            Some(rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked)
        );
        if busy {
            Self::Storage { code: ErrorCode::StorageBusy, message: "database is busy; lock timeout elapsed".into() }
        } else {
            Self::storage(format!("database error: {error}"))
        }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(error: std::io::Error) -> Self {
        Self::storage(format!("storage I/O error: {error}"))
    }
}

/// CSV syntax errors while reading an import document (0004). Structural
/// storage errors (`csv::ErrorKind::Io`) are exceedingly unlikely for an
/// in-memory `&[u8]` reader; both kinds are reported as `INVALID_IMPORT`
/// since either way the document could not be read.
impl From<csv::Error> for CoreError {
    fn from(error: csv::Error) -> Self {
        Self::invalid(ErrorCode::InvalidImport, format!("CSV syntax error: {error}"))
    }
}

pub type CoreResult<T> = Result<T, CoreError>;
