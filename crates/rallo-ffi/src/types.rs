use rallo_core::CoreError;
use rallo_core::items::{Item, ItemStatus as CoreItemStatus};
use rallo_core::preferences;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RalloError {
    #[error("{message}")]
    InvalidInput { code: String, message: String },
    #[error("{message}")]
    NotFound { code: String, message: String },
    #[error("{message}")]
    Storage { code: String, message: String },
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
}

impl From<Item> for ItemSnapshot {
    fn from(item: Item) -> Self {
        Self {
            id: item.id.to_string(),
            display_id: item.display_id().to_owned(),
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
        }
    }
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
