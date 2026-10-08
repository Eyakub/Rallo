use std::collections::HashMap;

use rusqlite::types::Value;
use rusqlite::{Connection, OptionalExtension, Row, Transaction, params, params_from_iter};
use uuid::Uuid;

use super::model::{Item, ItemStatus, ItemView, ListFilter, TagCount};
use super::query::{ItemScope, ListQuery, Page, SearchQuery};
use super::tags;
use crate::folders;
use crate::reminders;
use crate::shared::errors::{ConflictDetail, CoreError, CoreResult, ErrorCode};
use crate::shared::{ids, text};

const ITEM_COLUMNS: &str =
    "id, short_key, text, status, created_at_ms, updated_at_ms, completed_at_ms, deleted_at_ms, revision, folder_id";

fn item_from_row(row: &Row<'_>) -> rusqlite::Result<Item> {
    let id: String = row.get(0)?;
    let status: String = row.get(3)?;
    Ok(Item {
        id: Uuid::parse_str(&id)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))?,
        short_key: row.get(1)?,
        text: row.get(2)?,
        status: ItemStatus::parse(&status).ok_or_else(|| {
            rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, "unknown item status".into())
        })?,
        created_at_ms: row.get(4)?,
        updated_at_ms: row.get(5)?,
        completed_at_ms: row.get(6)?,
        deleted_at_ms: row.get(7)?,
        revision: row.get(8)?,
        folder_id: row
            .get::<_, Option<String>>(9)?
            .map(|id| Uuid::parse_str(&id))
            .transpose()
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(9, rusqlite::types::Type::Text, Box::new(e)))?,
    })
}

/// Same column layout as `item_from_row` with one trailing column appended by
/// the caller's query (used by the `due` listing's joined `deadline_ms`).
fn item_with_extra_from_row(row: &Row<'_>) -> rusqlite::Result<(Item, i64)> {
    Ok((item_from_row(row)?, row.get(10)?))
}

pub(crate) fn insert(conn: &Connection, item: &Item, match_key: &str) -> CoreResult<()> {
    conn.execute(
        "INSERT INTO items (id, short_key, text, match_key, status, created_at_ms, updated_at_ms,
                            completed_at_ms, deleted_at_ms, revision, folder_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            item.id.to_string(),
            item.short_key,
            item.text,
            match_key,
            item.status.as_str(),
            item.created_at_ms,
            item.updated_at_ms,
            item.completed_at_ms,
            item.deleted_at_ms,
            item.revision,
            item.folder_id.map(|id| id.to_string()),
        ],
    )?;
    Ok(())
}

pub(crate) fn get_by_id(conn: &Connection, id: Uuid) -> CoreResult<Option<Item>> {
    Ok(conn
        .query_row(&format!("SELECT {ITEM_COLUMNS} FROM items WHERE id = ?1"), [id.to_string()], item_from_row)
        .optional()?)
}

/// Every item — live and deleted — oldest first then id, for a full export
/// snapshot (0004). Deliberately unpaginated: export reads the whole store in
/// one read transaction.
pub(crate) fn all_items_for_export(conn: &Connection) -> CoreResult<Vec<Item>> {
    let mut statement =
        conn.prepare(&format!("SELECT {ITEM_COLUMNS} FROM items ORDER BY created_at_ms ASC, id ASC"))?;
    Ok(statement.query_map([], item_from_row)?.collect::<Result<_, _>>()?)
}

/// Id-less CSV import dedupe key (0004): an existing, nondeleted item with
/// byte-equal (unnormalized) text and the same `created_at_ms`. Deliberately
/// exact, not `match_key`: CSV rows without an id have no other identity to
/// go on.
pub(crate) fn find_by_exact_text_and_created_at(
    conn: &Connection,
    text: &str,
    created_at_ms: i64,
) -> CoreResult<Option<Item>> {
    Ok(conn
        .query_row(
            &format!(
                "SELECT {ITEM_COLUMNS} FROM items
                 WHERE text = ?1 AND created_at_ms = ?2 AND deleted_at_ms IS NULL LIMIT 1"
            ),
            params![text, created_at_ms],
            item_from_row,
        )
        .optional()?)
}

fn item_not_found() -> CoreError {
    CoreError::not_found(ErrorCode::ItemNotFound, "no item matches that id")
}

fn invalid_id() -> CoreError {
    CoreError::invalid(ErrorCode::InvalidId, "id must be a UUID or at least 6 characters of Crockford Base32")
}

/// Selector resolution (0003 §6): a UUID is an exact lookup; otherwise a
/// normalized Base32 prefix of at least 6 characters is matched against
/// `short_key` with an indexed range scan. Includes deleted items.
pub(crate) fn resolve(conn: &Connection, raw: &str) -> CoreResult<Item> {
    if let Ok(id) = Uuid::parse_str(raw) {
        return get_by_id(conn, id)?.ok_or_else(item_not_found);
    }
    let normalized = ids::normalize_prefix(raw).ok_or_else(invalid_id)?;
    if normalized.len() < ids::MIN_PREFIX_LEN {
        return Err(invalid_id());
    }
    let upper = ids::prefix_upper_bound(&normalized);
    let mut statement = conn.prepare_cached(&format!(
        "SELECT {ITEM_COLUMNS} FROM items WHERE short_key >= ?1 AND short_key < ?2 ORDER BY short_key LIMIT 11"
    ))?;
    let matches: Vec<Item> =
        statement.query_map(params![normalized, upper], item_from_row)?.collect::<Result<_, _>>()?;
    match matches.len() {
        0 => Err(item_not_found()),
        1 => Ok(matches.into_iter().next().expect("length checked above")),
        _ => {
            let total: i64 = conn.query_row(
                "SELECT COUNT(*) FROM items WHERE short_key >= ?1 AND short_key < ?2",
                params![normalized, upper],
                |row| row.get(0),
            )?;
            let total = total as u64;
            let candidates =
                matches.into_iter().take(10).map(|item| build_item_view(conn, item)).collect::<CoreResult<Vec<_>>>()?;
            Err(CoreError::conflict_detail(
                ErrorCode::AmbiguousId,
                format!("{total} items match prefix \"{normalized}\""),
                ConflictDetail::Candidates { total, candidates },
            ))
        }
    }
}

/// Display ID (0003 §6): the shortest prefix of `item.short_key`, at least 6
/// characters, that neither of its immediate short_key neighbours shares.
/// Sorted order guarantees no other item can share a prefix its neighbours
/// don't.
pub(crate) fn display_id(conn: &Connection, item: &Item) -> CoreResult<String> {
    let prev: Option<String> = conn
        .query_row(
            "SELECT short_key FROM items WHERE short_key < ?1 ORDER BY short_key DESC LIMIT 1",
            [&item.short_key],
            |row| row.get(0),
        )
        .optional()?;
    let next: Option<String> = conn
        .query_row(
            "SELECT short_key FROM items WHERE short_key > ?1 ORDER BY short_key ASC LIMIT 1",
            [&item.short_key],
            |row| row.get(0),
        )
        .optional()?;

    let mut len = ids::MIN_PREFIX_LEN;
    while len < ids::SHORT_KEY_LEN {
        let candidate = &item.short_key[..len];
        let collides = prev.as_deref().is_some_and(|key| key.starts_with(candidate))
            || next.as_deref().is_some_and(|key| key.starts_with(candidate));
        if !collides {
            break;
        }
        len += 1;
    }
    Ok(item.short_key[..len].to_owned())
}

pub(crate) fn build_item_view(conn: &Connection, item: Item) -> CoreResult<ItemView> {
    let display_id = display_id(conn, &item)?;
    let reminder = reminders::repository::fetch_by_item(conn, item.id)?;
    let images = crate::images::views(conn, item.id)?;
    let folder = crate::folders::repository::folder_ref(conn, item.folder_id)?;
    let tags = super::tags::tags(&item.text);
    Ok(ItemView { item, display_id, reminder, images, folder, tags })
}

fn validate_limit(limit: u32) -> CoreResult<u32> {
    if (1..=200).contains(&limit) {
        Ok(limit)
    } else {
        Err(CoreError::invalid(ErrorCode::InvalidInput, format!("limit must be between 1 and 200 (got {limit})")))
    }
}

/// Opaque pagination cursor: hex of `"<sort value>:<item id>"`.
fn encode_cursor(sort_value: i64, id: Uuid) -> String {
    format!("{sort_value}:{id}").into_bytes().iter().map(|byte| format!("{byte:02x}")).collect()
}

// `is_multiple_of`/`as_chunks` postdate this workspace's 1.89 MSRV.
#[allow(clippy::manual_is_multiple_of, clippy::chunks_exact_to_as_chunks)]
fn decode_cursor(cursor: &str) -> CoreResult<(i64, Uuid)> {
    (|| {
        if cursor.is_empty() || cursor.len() % 2 != 0 {
            return None;
        }
        let mut bytes = Vec::with_capacity(cursor.len() / 2);
        for chunk in cursor.as_bytes().chunks_exact(2) {
            bytes.push(u8::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok()?);
        }
        let raw = String::from_utf8(bytes).ok()?;
        let (sort_value, id) = raw.split_once(':')?;
        Some((sort_value.parse().ok()?, Uuid::parse_str(id).ok()?))
    })()
    .ok_or_else(|| CoreError::invalid(ErrorCode::InvalidInput, "cursor is malformed"))
}

/// A scope with its folder and tag resolved, ready for SQL.
pub(crate) struct Scope {
    /// `Some(None)` is Notes.
    folder: Option<Option<Uuid>>,
    tag: Option<String>,
}

impl Scope {
    pub(crate) fn resolve(conn: &Connection, scope: &ItemScope) -> CoreResult<Self> {
        let folder = scope
            .folder
            .as_ref()
            .map(|selector| folders::repository::resolve(conn, selector).map(|folder| folder.map(|folder| folder.id)))
            .transpose()?;
        let tag = scope.tag.as_deref().map(tags::parse_tag_argument).transpose()?;
        Ok(Self { folder, tag })
    }
}

/// A `WHERE` body under construction: anonymous `?` placeholders and their
/// values, kept in the order they appear.
struct Filter {
    sql: String,
    args: Vec<Value>,
}

impl Filter {
    fn new(base: &str, args: Vec<Value>) -> Self {
        Self { sql: base.to_owned(), args }
    }

    fn and(mut self, clause: &str, args: Vec<Value>) -> Self {
        self.sql.push_str(" AND ");
        self.sql.push_str(clause);
        self.args.extend(args);
        self
    }

    /// Adds the folder and tag restrictions; `column` prefixes the item's
    /// columns (`"i."` in a join, `""` otherwise).
    fn scoped(mut self, scope: &Scope, column: &str) -> Self {
        match scope.folder {
            None => {}
            Some(None) => self = self.and(&format!("{column}folder_id IS NULL"), vec![]),
            Some(Some(id)) => self = self.and(&format!("{column}folder_id = ?"), vec![Value::Text(id.to_string())]),
        }
        if let Some(tag) = &scope.tag {
            self = self.and(&format!("rallo_has_tag({column}text, ?)"), vec![Value::Text(tag.clone())]);
        }
        self
    }

    fn count(&self, conn: &Connection, from: &str) -> CoreResult<u64> {
        let total: i64 = conn.query_row(
            &format!("SELECT COUNT(*) FROM {from} WHERE {}", self.sql),
            params_from_iter(&self.args),
            |row| row.get(0),
        )?;
        Ok(total as u64)
    }
}

pub(crate) fn list(conn: &Connection, query: &ListQuery, scope: &Scope, now_ms: i64) -> CoreResult<Page<ItemView>> {
    let limit = validate_limit(query.limit)?;
    let cursor = query.cursor.as_deref();
    let page = |base: &str, sort_column: &str| {
        simple_page(conn, Filter::new(base, vec![]).scoped(scope, ""), sort_column, cursor, limit)
    };
    match query.filter {
        ListFilter::Open => page("deleted_at_ms IS NULL AND status = 'open'", "created_at_ms"),
        ListFilter::All => page("deleted_at_ms IS NULL", "created_at_ms"),
        ListFilter::Deleted => page("deleted_at_ms IS NOT NULL", "deleted_at_ms"),
        ListFilter::Done => page("deleted_at_ms IS NULL AND status = 'done'", "completed_at_ms"),
        ListFilter::Due => due_page(conn, scope, cursor, limit, now_ms),
    }
}

/// Shared shape for the `open`/`all`/`deleted`/`done` filters: a
/// single-column, newest-first sort over `items` alone, ties broken by `id`.
fn simple_page(
    conn: &Connection,
    filter: Filter,
    sort_column: &str,
    cursor: Option<&str>,
    limit: u32,
) -> CoreResult<Page<ItemView>> {
    let total_count = filter.count(conn, "items")?;
    let filter = match cursor.map(decode_cursor).transpose()? {
        Some((sort_value, id)) => filter.and(
            &format!("({sort_column}, id) < (?, ?)"),
            vec![Value::Integer(sort_value), Value::Text(id.to_string())],
        ),
        None => filter,
    };
    let sql =
        format!("SELECT {ITEM_COLUMNS} FROM items WHERE {} ORDER BY {sort_column} DESC, id DESC LIMIT ?", filter.sql);
    let mut args = filter.args;
    args.push(Value::Integer(i64::from(limit) + 1));
    let mut statement = conn.prepare(&sql)?;
    let rows: Vec<Item> = statement.query_map(params_from_iter(&args), item_from_row)?.collect::<Result<_, _>>()?;

    paginate(conn, rows, limit, total_count, |item| match sort_column {
        "created_at_ms" => item.created_at_ms,
        "deleted_at_ms" => item.deleted_at_ms.expect("the deleted filter only selects rows with deleted_at_ms set"),
        "completed_at_ms" => item.completed_at_ms.expect("the done filter only selects rows with completed_at_ms set"),
        other => unreachable!("unexpected sort column {other}"),
    })
}

/// `due`: open items with an active reminder whose deadline has passed,
/// earliest deadline first.
fn due_page(
    conn: &Connection,
    scope: &Scope,
    cursor: Option<&str>,
    limit: u32,
    now_ms: i64,
) -> CoreResult<Page<ItemView>> {
    const JOIN_COLUMNS: &str = "i.id, i.short_key, i.text, i.status, i.created_at_ms, i.updated_at_ms, \
                                 i.completed_at_ms, i.deleted_at_ms, i.revision, i.folder_id, r.deadline_ms";
    const FROM: &str = "items i JOIN reminders r ON r.item_id = i.id";

    let filter = Filter::new(
        "i.deleted_at_ms IS NULL AND i.status = 'open' AND r.enabled = 1 AND r.deadline_ms <= ?",
        vec![Value::Integer(now_ms)],
    )
    .scoped(scope, "i.");
    let total_count = filter.count(conn, FROM)?;
    let filter = match cursor.map(decode_cursor).transpose()? {
        Some((sort_value, id)) => {
            filter.and("(r.deadline_ms, i.id) > (?, ?)", vec![Value::Integer(sort_value), Value::Text(id.to_string())])
        }
        None => filter,
    };
    let sql =
        format!("SELECT {JOIN_COLUMNS} FROM {FROM} WHERE {} ORDER BY r.deadline_ms ASC, i.id ASC LIMIT ?", filter.sql);
    let mut args = filter.args;
    args.push(Value::Integer(i64::from(limit) + 1));
    let mut statement = conn.prepare(&sql)?;
    let mut rows: Vec<(Item, i64)> =
        statement.query_map(params_from_iter(&args), item_with_extra_from_row)?.collect::<Result<_, _>>()?;

    let has_more = rows.len() as u32 > limit;
    rows.truncate(limit as usize);
    let next_cursor = has_more.then(|| {
        let (item, deadline_ms) = rows.last().expect("has_more implies at least one row");
        encode_cursor(*deadline_ms, item.id)
    });
    let items = rows.into_iter().map(|(item, _)| build_item_view(conn, item)).collect::<CoreResult<Vec<_>>>()?;
    Ok(Page { items, total_count, next_cursor })
}

fn paginate(
    conn: &Connection,
    mut rows: Vec<Item>,
    limit: u32,
    total_count: u64,
    sort_value: impl Fn(&Item) -> i64,
) -> CoreResult<Page<ItemView>> {
    let has_more = rows.len() as u32 > limit;
    rows.truncate(limit as usize);
    let next_cursor = has_more.then(|| {
        let last = rows.last().expect("has_more implies at least one row");
        encode_cursor(sort_value(last), last.id)
    });
    let items = rows.into_iter().map(|item| build_item_view(conn, item)).collect::<CoreResult<Vec<_>>>()?;
    Ok(Page { items, total_count, next_cursor })
}

/// Literal substring (or, with `exact`, equality) search over `match_key`
/// (0003 §10). No LIKE/regex; may full-scan.
pub(crate) fn search(conn: &Connection, query: &SearchQuery, scope: &Scope) -> CoreResult<Page<ItemView>> {
    if query.text.trim().is_empty() {
        return Err(CoreError::invalid(ErrorCode::TextEmpty, "search text is empty"));
    }
    text::validate_note_text(&query.text)?;
    let limit = validate_limit(query.limit)?;
    let key = text::match_key(&query.text);
    let match_clause = if query.exact { "match_key = ?" } else { "instr(match_key, ?) > 0" };
    let mut filter = Filter::new(match_clause, vec![Value::Text(key)]);
    if !query.include_deleted {
        filter = filter.and("deleted_at_ms IS NULL", vec![]);
    }
    simple_page(conn, filter.scoped(scope, ""), "created_at_ms", query.cursor.as_deref(), limit)
}

/// Open, nondeleted notes per tag (0019 §6): most used first, then
/// alphabetical. Tags found only in done or deleted notes are left out.
// ponytail: scans every open note's text; fine to tens of thousands (0019 §7).
pub(crate) fn tag_counts(conn: &Connection) -> CoreResult<Vec<TagCount>> {
    let mut statement = conn
        .prepare("SELECT text FROM items WHERE deleted_at_ms IS NULL AND status = 'open' AND instr(text, '#') > 0")?;
    let mut counts: HashMap<String, u64> = HashMap::new();
    for text in statement.query_map([], |row| row.get::<_, String>(0))? {
        for key in tags::tags(&text?) {
            *counts.entry(key).or_default() += 1;
        }
    }
    let mut counts: Vec<TagCount> =
        counts.into_iter().map(|(name, open_count)| TagCount { name, open_count }).collect();
    counts.sort_by(|a, b| b.open_count.cmp(&a.open_count).then_with(|| a.name.cmp(&b.name)));
    Ok(counts)
}

/// Exact `match_key` candidates among nondeleted items (open and done), for
/// `delete --text` (0003 §8). Capped at 11 so the caller can distinguish "one
/// match" from "more than one" without a second round trip.
pub(crate) fn find_exact_nondeleted(conn: &Connection, match_key: &str) -> CoreResult<Vec<Item>> {
    let mut statement = conn.prepare_cached(&format!(
        "SELECT {ITEM_COLUMNS} FROM items WHERE match_key = ?1 AND deleted_at_ms IS NULL
         ORDER BY created_at_ms DESC, id DESC LIMIT 11"
    ))?;
    Ok(statement.query_map([match_key], item_from_row)?.collect::<Result<_, _>>()?)
}

pub(crate) fn count_exact_nondeleted(conn: &Connection, match_key: &str) -> CoreResult<u64> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM items WHERE match_key = ?1 AND deleted_at_ms IS NULL",
        [match_key],
        |row| row.get(0),
    )?;
    Ok(count as u64)
}

pub(crate) fn update_text(
    tx: &Transaction<'_>,
    item_id: Uuid,
    text: &str,
    match_key: &str,
    now_ms: i64,
) -> CoreResult<()> {
    tx.execute(
        "UPDATE items SET text = ?2, match_key = ?3, updated_at_ms = ?4, revision = revision + 1 WHERE id = ?1",
        params![item_id.to_string(), text, match_key, now_ms],
    )?;
    Ok(())
}

pub(crate) fn mark_done(tx: &Transaction<'_>, item_id: Uuid, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE items SET status = 'done', completed_at_ms = ?2, updated_at_ms = ?2, revision = revision + 1
         WHERE id = ?1",
        params![item_id.to_string(), now_ms],
    )?;
    Ok(())
}

pub(crate) fn mark_open(tx: &Transaction<'_>, item_id: Uuid, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE items SET status = 'open', completed_at_ms = NULL, updated_at_ms = ?2, revision = revision + 1
         WHERE id = ?1",
        params![item_id.to_string(), now_ms],
    )?;
    Ok(())
}

pub(crate) fn mark_deleted(tx: &Transaction<'_>, item_id: Uuid, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE items SET deleted_at_ms = ?2, updated_at_ms = ?2, revision = revision + 1 WHERE id = ?1",
        params![item_id.to_string(), now_ms],
    )?;
    Ok(())
}

pub(crate) fn mark_restored(tx: &Transaction<'_>, item_id: Uuid, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE items SET deleted_at_ms = NULL, updated_at_ms = ?2, revision = revision + 1 WHERE id = ?1",
        params![item_id.to_string(), now_ms],
    )?;
    Ok(())
}

/// Bumps `revision`/`updated_at_ms` without touching any other column: used
/// by reminder-only mutations (`reschedule`, `snooze`, `acknowledge`,
/// `cancel-reminder`) whose state change lives entirely in the `reminders`
/// table but which must still bump the item's revision exactly once (0003
/// §3). Also used for image add/remove (0018).
pub(crate) fn touch(tx: &Connection, item_id: Uuid, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE items SET updated_at_ms = ?2, revision = revision + 1 WHERE id = ?1",
        params![item_id.to_string(), now_ms],
    )?;
    Ok(())
}

/// Moves an item to a folder (`None` is Notes), bumping its revision (0019 §5).
pub(crate) fn set_folder(tx: &Transaction<'_>, item_id: Uuid, folder_id: Option<Uuid>, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE items SET folder_id = ?2, updated_at_ms = ?3, revision = revision + 1 WHERE id = ?1",
        params![item_id.to_string(), folder_id.map(|id| id.to_string()), now_ms],
    )?;
    Ok(())
}
