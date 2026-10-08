use serde::Serialize;
use uuid::Uuid;

use crate::reminders::model::{CancellationStatus, Reminder, SchedulingStatus};

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
    /// `None` is the built-in "Notes" folder (0019). Item JSON carries it as
    /// `folder: {id, name}` on `ItemView` instead.
    #[serde(skip)]
    pub folder_id: Option<Uuid>,
}

/// An item plus the resolution-time context that only makes sense alongside
/// it: its current display ID and reminder, if any. This is the shape
/// exposed at the CLI/FFI boundary (0003 §11), not `Item` alone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ItemView {
    #[serde(flatten)]
    pub item: Item,
    pub display_id: String,
    pub reminder: Option<Reminder>,
    /// The note's images in order (0018); `[]` when it has none.
    pub images: Vec<crate::images::ImageView>,
    /// The note's folder, or `null` for Notes (0019 §6).
    pub folder: Option<crate::folders::FolderRef>,
    /// Tag keys in the text, first-appearance order, no duplicates (0019 §6).
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ListFilter {
    /// Open, nondeleted items.
    #[default]
    Open,
    /// Open and done, nondeleted items.
    All,
    /// Deleted items.
    Deleted,
    /// Open items with an active reminder whose deadline has passed.
    Due,
}

/// One line of `rallo tags` (0019 §6): `open_count` is open, nondeleted notes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagCount {
    pub name: String,
    pub open_count: u64,
}

/// Idempotency and optimistic-concurrency controls accepted by every
/// ID-based mutation (0003 §7, §9).
#[derive(Debug, Clone, Default)]
pub struct MutationOptions {
    pub request_id: Option<String>,
    pub if_revision: Option<i64>,
}

/// Result of a mutation attempt: the current snapshot plus whether it did
/// anything and whether this was an idempotent replay.
#[derive(Debug, Clone)]
pub struct MutationOutcome {
    pub item: ItemView,
    pub changed: bool,
    pub replayed: bool,
    pub scheduling: Option<SchedulingStatus>,
    pub cancellation: Option<CancellationStatus>,
}
