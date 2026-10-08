use serde::Serialize;

use super::model::ListFilter;
use crate::folders::FolderSelector;

/// `rallo list` parameters (0003 §10).
#[derive(Debug, Clone)]
pub struct ListQuery {
    pub filter: ListFilter,
    pub limit: u32,
    /// Opaque cursor from a previous page's `next_cursor`.
    pub cursor: Option<String>,
}

/// `rallo search` parameters (0003 §10).
#[derive(Debug, Clone)]
pub struct SearchQuery {
    pub text: String,
    pub exact: bool,
    pub include_deleted: bool,
    pub limit: u32,
    pub cursor: Option<String>,
}

/// Folder and tag restrictions for `list` and `search` (0019 §6). They are
/// SQL `WHERE` clauses, so `total_count` and cursors cover only what matches,
/// and they AND with each other and with every `ListFilter`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ItemScope {
    /// `None`: every folder. `Some(FolderSelector::Notes)`: only notes with no folder.
    pub folder: Option<FolderSelector>,
    /// A tag with or without its `#` (`parse_tag_argument`); anything else is `INVALID_INPUT`.
    pub tag: Option<String>,
}

/// One page of results. `total_count` is independent of `limit`/`cursor`, so
/// callers can tell a unique match from a merely short page.
#[derive(Debug, Clone, Serialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub total_count: u64,
    pub next_cursor: Option<String>,
}
