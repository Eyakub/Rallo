use serde::Serialize;

use super::model::ListFilter;

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

/// One page of results. `total_count` is independent of `limit`/`cursor`, so
/// callers can tell a unique match from a merely short page.
#[derive(Debug, Clone, Serialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub total_count: u64,
    pub next_cursor: Option<String>,
}
