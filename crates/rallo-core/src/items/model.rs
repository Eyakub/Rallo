use serde::Serialize;
use uuid::Uuid;

use crate::shared::ids::MIN_PREFIX_LEN;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemStatus {
    Open,
    Done,
}

impl ItemStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Done => "done",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "open" => Some(Self::Open),
            "done" => Some(Self::Done),
            _ => None,
        }
    }
}

/// Snapshot of one item at a specific revision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Item {
    pub id: Uuid,
    #[serde(skip)]
    pub short_key: String,
    pub text: String,
    pub status: ItemStatus,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub completed_at_ms: Option<i64>,
    pub deleted_at_ms: Option<i64>,
    pub revision: i64,
}

impl Item {
    /// Minimum-length display prefix. Uniqueness extension arrives with ID
    /// resolution in M1.
    pub fn display_id(&self) -> &str {
        &self.short_key[..MIN_PREFIX_LEN]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ListFilter {
    /// Open, nondeleted items.
    #[default]
    Open,
}
