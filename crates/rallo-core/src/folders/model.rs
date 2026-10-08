use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::shared::text;

/// Longest folder name, in characters after trimming (0019 §3).
pub const MAX_NAME_CHARS: usize = 50;

/// The `name_key` that "Notes" folds to; no folder may have it (0019 §3).
pub(crate) const NOTES_KEY: &str = "notes";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Folder {
    pub id: Uuid,
    pub name: String,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub revision: i64,
}

/// What an item's JSON says about its folder: `{"id", "name"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FolderRef {
    pub id: Uuid,
    pub name: String,
}

/// A folder as the caller names it. The CLI names folders by name, the FFI by
/// id; `Notes` is the built-in folder (`items.folder_id IS NULL`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FolderSelector {
    Notes,
    /// Matched on `name_key`, so case and Unicode composition don't matter.
    /// Build it with [`FolderSelector::named`], which maps "Notes" to `Notes`.
    Name(String),
    Id(Uuid),
}

impl FolderSelector {
    /// A folder named by a person: "Notes" in any case means no folder.
    pub fn named(name: &str) -> Self {
        if text::match_key(name) == NOTES_KEY { Self::Notes } else { Self::Name(name.to_owned()) }
    }

    /// The selector as an idempotency fingerprint carries it: `None` for
    /// Notes, else the name key or the id.
    pub(crate) fn fingerprint(&self) -> Option<String> {
        match self {
            Self::Notes => None,
            Self::Name(name) => Some(text::match_key(name)),
            Self::Id(id) => Some(id.to_string()),
        }
    }
}

/// One line of `rallo folders`: `folder: None` is Notes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderCount {
    pub folder: Option<Folder>,
    /// Open and done, nondeleted notes: what "It holds N notes" counts (0019 §9, §12).
    pub note_count: u64,
    /// Open, nondeleted notes (0019 §1).
    pub open_count: u64,
}

/// What `folder delete` was asked to do with the notes it holds (0019 §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteNotes {
    /// `--keep-notes`: they go to Notes.
    Keep,
    /// `--delete-notes`: they are soft-deleted, then go to Notes.
    Delete,
}

/// What `folder delete` did with the nondeleted notes the folder held.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotesDisposition {
    Kept,
    Deleted,
    /// The folder held no nondeleted notes.
    None,
}

/// Result of `folder create` and `folder rename`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FolderOutcome {
    pub folder: Folder,
    pub changed: bool,
    pub replayed: bool,
}

/// Result of `folder delete`. `folder` is the folder as it was.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FolderDeleteOutcome {
    pub folder: Folder,
    pub notes: NotesDisposition,
    /// Nondeleted notes that went to Notes.
    pub moved: u64,
    /// Nondeleted notes that were soft-deleted.
    pub deleted: u64,
    /// How many of those had an active reminder, now disabled with a cancel
    /// intent queued; tells the CLI whether the app has native work to do.
    pub reminders_cancelled: u64,
    pub replayed: bool,
}

/// Trimmed name and its `name_key` (0019 §3): 1-50 characters, no control
/// characters or line breaks, and not "Notes".
pub fn validate_name(raw: &str) -> CoreResult<(String, String)> {
    let name = raw.trim();
    let chars = name.chars().count();
    if chars == 0 || chars > MAX_NAME_CHARS {
        return Err(CoreError::invalid(
            ErrorCode::FolderNameInvalid,
            format!("a folder name is 1-{MAX_NAME_CHARS} characters (got {chars})"),
        ));
    }
    if name.chars().any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')) {
        return Err(CoreError::invalid(
            ErrorCode::FolderNameInvalid,
            "a folder name can't contain control characters or line breaks",
        ));
    }
    let key = text::match_key(name);
    if key == NOTES_KEY {
        return Err(CoreError::invalid(
            ErrorCode::FolderNameInvalid,
            "\u{201c}Notes\u{201d} is the built-in folder's name",
        ));
    }
    Ok((name.to_owned(), key))
}
