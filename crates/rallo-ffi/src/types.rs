use rallo_core::CoreError;
use rallo_core::items::{ItemStatus as CoreItemStatus, ItemView};
use rallo_core::preferences;
use rallo_core::reminders;
use rallo_core::transfer::{ExportFormat, ImportConflictRecord, ImportReport};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RalloError {
    #[error("{message}")]
    InvalidInput { code: String, message: String },
    #[error("{message}")]
    NotFound { code: String, message: String },
    #[error("{message}")]
    Storage { code: String, message: String },
    /// Ambiguous selection, a stale revision, a request-id collision, or a
    /// precondition failure. The structured detail stays on the Rust side for
    /// now; Swift gets the code and message.
    #[error("{message}")]
    Conflict { code: String, message: String },
    #[error("{message}")]
    IncompatibleSchema { found: u32, supported: u32, message: String },
}

impl From<CoreError> for RalloError {
    fn from(error: CoreError) -> Self {
        let code = error.code().as_str().to_owned();
        let message = error.to_string();
        match error {
            CoreError::InvalidInput { .. } => Self::InvalidInput { code, message },
            CoreError::NotFound { .. } => Self::NotFound { code, message },
            CoreError::Storage { .. } => Self::Storage { code, message },
            CoreError::Conflict { .. } => Self::Conflict { code, message },
            CoreError::IncompatibleSchema { found, supported } => {
                Self::IncompatibleSchema { found, supported, message }
            }
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CoreInfo {
    pub core_version: String,
    pub schema_version: u32,
    pub json_contract_version: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ItemStatus {
    Open,
    Done,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ItemSnapshot {
    pub id: String,
    pub display_id: String,
    pub text: String,
    pub status: ItemStatus,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub completed_at_ms: Option<i64>,
    pub deleted_at_ms: Option<i64>,
    pub revision: i64,
    pub reminder: Option<ReminderSnapshot>,
}

impl From<ItemView> for ItemSnapshot {
    fn from(view: ItemView) -> Self {
        let item = view.item;
        Self {
            id: item.id.to_string(),
            display_id: view.display_id,
            status: match item.status {
                CoreItemStatus::Open => ItemStatus::Open,
                CoreItemStatus::Done => ItemStatus::Done,
            },
            text: item.text,
            created_at_ms: item.created_at_ms,
            updated_at_ms: item.updated_at_ms,
            completed_at_ms: item.completed_at_ms,
            deleted_at_ms: item.deleted_at_ms,
            revision: item.revision,
            reminder: view.reminder.map(|reminder| ReminderSnapshot {
                id: reminder.id.to_string(),
                deadline_ms: reminder.deadline_ms,
                state: reminder.state().into(),
                scheduling_state: None,
                scheduling_reason: None,
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReminderState {
    Active,
    Acknowledged,
    Cancelled,
    Completed,
    Deleted,
}

impl From<reminders::ReminderState> for ReminderState {
    fn from(state: reminders::ReminderState) -> Self {
        match state {
            reminders::ReminderState::Active => Self::Active,
            reminders::ReminderState::Acknowledged => Self::Acknowledged,
            reminders::ReminderState::Cancelled => Self::Cancelled,
            reminders::ReminderState::Completed => Self::Completed,
            reminders::ReminderState::Deleted => Self::Deleted,
        }
    }
}

/// Scheduling fields come from the core's status computation (e.g.
/// "pending"/"awaiting_app"); Swift displays them and never derives them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReminderSnapshot {
    pub id: String,
    pub deadline_ms: i64,
    pub state: ReminderState,
    pub scheduling_state: Option<String>,
    pub scheduling_reason: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PetVisibility {
    Visible,
    Hidden,
}

impl From<preferences::PetVisibility> for PetVisibility {
    fn from(value: preferences::PetVisibility) -> Self {
        match value {
            preferences::PetVisibility::Visible => Self::Visible,
            preferences::PetVisibility::Hidden => Self::Hidden,
        }
    }
}

impl From<PetVisibility> for preferences::PetVisibility {
    fn from(value: PetVisibility) -> Self {
        match value {
            PetVisibility::Visible => Self::Visible,
            PetVisibility::Hidden => Self::Hidden,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct PetPlacement {
    pub x: f64,
    pub y: f64,
}

impl From<preferences::PetPlacement> for PetPlacement {
    fn from(value: preferences::PetPlacement) -> Self {
        Self { x: value.x, y: value.y }
    }
}

impl From<PetPlacement> for preferences::PetPlacement {
    fn from(value: PetPlacement) -> Self {
        Self { x: value.x, y: value.y }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TransferFormat {
    Json,
    Csv,
}

impl From<TransferFormat> for ExportFormat {
    fn from(format: TransferFormat) -> Self {
        match format {
            TransferFormat::Json => Self::Json,
            TransferFormat::Csv => Self::Csv,
        }
    }
}

impl From<ExportFormat> for TransferFormat {
    fn from(format: ExportFormat) -> Self {
        match format {
            ExportFormat::Json => Self::Json,
            ExportFormat::Csv => Self::Csv,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExportResult {
    pub items: u64,
    pub path: String,
}

/// Where a conflicting record is in the file; never its note text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportConflict {
    pub id: Option<String>,
    pub line: Option<u64>,
    pub index: Option<u64>,
    pub reason: String,
}

impl From<ImportConflictRecord> for ImportConflict {
    fn from(record: ImportConflictRecord) -> Self {
        Self { id: record.id.map(|id| id.to_string()), line: record.line, index: record.index, reason: record.reason }
    }
}

/// A dry run (`applied == false`) or the committed result of an import.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportSummary {
    pub format: TransferFormat,
    pub total_records: u64,
    pub new: u64,
    pub identical: u64,
    pub conflicts: Vec<ImportConflict>,
    pub conflict_total: u64,
    pub warnings: Vec<String>,
    pub applied: bool,
    pub backup_path: Option<String>,
}

impl From<ImportReport> for ImportSummary {
    fn from(report: ImportReport) -> Self {
        Self {
            format: report.format.into(),
            total_records: report.total_records,
            new: report.new,
            identical: report.identical,
            conflicts: report.conflicts.into_iter().map(Into::into).collect(),
            conflict_total: report.conflict_total,
            warnings: report.warnings,
            applied: report.applied,
            backup_path: report.backup_path.map(|path| path.display().to_string()),
        }
    }
}
