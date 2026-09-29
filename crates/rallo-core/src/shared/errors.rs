use serde::Serialize;

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
        }
    }
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
    #[error("database schema version {found} is newer than this build supports ({supported})")]
    IncompatibleSchema { found: u32, supported: u32 },
}

impl CoreError {
    pub fn code(&self) -> ErrorCode {
        match self {
            Self::InvalidInput { code, .. } | Self::NotFound { code, .. } | Self::Storage { code, .. } => *code,
            Self::IncompatibleSchema { .. } => ErrorCode::IncompatibleSchema,
        }
    }

    pub(crate) fn invalid(code: ErrorCode, message: impl Into<String>) -> Self {
        Self::InvalidInput { code, message: message.into() }
    }

    pub(crate) fn storage(message: impl Into<String>) -> Self {
        Self::Storage { code: ErrorCode::StorageUnavailable, message: message.into() }
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

pub type CoreResult<T> = Result<T, CoreError>;
