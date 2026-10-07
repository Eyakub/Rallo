use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use uuid::Uuid;

use super::model::{Item, ItemStatus, ItemView, ListFilter};
use super::query::{ListQuery, Page, SearchQuery};
use crate::reminders;
use crate::shared::errors::{ConflictDetail, CoreError, CoreResult, ErrorCode};
use crate::shared::{ids, text};

const ITEM_COLUMNS: &str =
    "id, short_key, text, status, created_at_ms, updated_at_ms, completed_at_ms, deleted_at_ms, revision";

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
    })
}

/// Same column layout as `item_from_row` with one trailing column appended by
/// the caller's query (used by the `due` listing's joined `deadline_ms`).
fn item_with_extra_from_row(row: &Row<'_>) -> rusqlite::Result<(Item, i64)> {
    Ok((item_from_row(row)?, row.get(9)?))
}

pub(crate) fn insert(conn: &Connection, item: &Item, match_key: &str) -> CoreResult<()> {
    conn.execute(
        "INSERT INTO items (id, short_key, text, match_key, status, created_at_ms, updated_at_ms,
                            completed_at_ms, deleted_at_ms, revision)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
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
    Ok(ItemView { item, display_id, reminder, images })
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

pub(crate) fn list(conn: &Connection, query: &ListQuery, now_ms: i64) -> CoreResult<Page<ItemView>> {
    let limit = validate_limit(query.limit)?;
    match query.filter {
        ListFilter::Open => simple_page(
            conn,
            "deleted_at_ms IS NULL AND status = 'open'",
            "created_at_ms",
            query.cursor.as_deref(),
            limit,
        ),
        ListFilter::All => simple_page(conn, "deleted_at_ms IS NULL", "created_at_ms", query.cursor.as_deref(), limit),
        ListFilter::Deleted => {
            simple_page(conn, "deleted_at_ms IS NOT NULL", "deleted_at_ms", query.cursor.as_deref(), limit)
        }
        ListFilter::Due => due_page(conn, query.cursor.as_deref(), limit, now_ms),
    }
}

/// Shared shape for the `open`/`all`/`deleted` filters: a single-column,
/// newest-first sort over `items` alone, ties broken by `id`.
fn simple_page(
    conn: &Connection,
    where_clause: &str,
    sort_column: &str,
    cursor: Option<&str>,
    limit: u32,
) -> CoreResult<Page<ItemView>> {
    let total_count: i64 =
        conn.query_row(&format!("SELECT COUNT(*) FROM items WHERE {where_clause}"), [], |row| row.get(0))?;
    let total_count = total_count as u64;

    let cursor = cursor.map(decode_cursor).transpose()?;
    let sql = format!(
        "SELECT {ITEM_COLUMNS} FROM items WHERE {where_clause}{cursor_clause}
         ORDER BY {sort_column} DESC, id DESC LIMIT ?{limit_param}",
        cursor_clause = if cursor.is_some() { format!(" AND ({sort_column}, id) < (?1, ?2)") } else { String::new() },
        limit_param = if cursor.is_some() { 3 } else { 1 },
    );
    let mut statement = conn.prepare(&sql)?;
    let rows: Vec<Item> = if let Some((sort_value, id)) = cursor {
        statement
            .query_map(params![sort_value, id.to_string(), i64::from(limit) + 1], item_from_row)?
            .collect::<Result<_, _>>()?
    } else {
        statement.query_map(params![i64::from(limit) + 1], item_from_row)?.collect::<Result<_, _>>()?
    };

    paginate(conn, rows, limit, total_count, |item| match sort_column {
        "created_at_ms" => item.created_at_ms,
        "deleted_at_ms" => item.deleted_at_ms.expect("the deleted filter only selects rows with deleted_at_ms set"),
        other => unreachable!("unexpected sort column {other}"),
    })
}

/// `due`: open items with an active reminder whose deadline has passed,
/// earliest deadline first.
fn due_page(conn: &Connection, cursor: Option<&str>, limit: u32, now_ms: i64) -> CoreResult<Page<ItemView>> {
    const JOIN_COLUMNS: &str = "i.id, i.short_key, i.text, i.status, i.created_at_ms, i.updated_at_ms, \
                                 i.completed_at_ms, i.deleted_at_ms, i.revision, r.deadline_ms";
    const BASE_WHERE: &str = "i.deleted_at_ms IS NULL AND i.status = 'open' AND r.enabled = 1 AND r.deadline_ms <= ?1";

    let total_count: i64 = conn.query_row(
        &format!("SELECT COUNT(*) FROM items i JOIN reminders r ON r.item_id = i.id WHERE {BASE_WHERE}"),
        [now_ms],
        |row| row.get(0),
    )?;
    let total_count = total_count as u64;

    let cursor = cursor.map(decode_cursor).transpose()?;
    let sql = format!(
        "SELECT {JOIN_COLUMNS} FROM items i JOIN reminders r ON r.item_id = i.id WHERE {BASE_WHERE}{cursor_clause}
         ORDER BY r.deadline_ms ASC, i.id ASC LIMIT ?{limit_param}",
        cursor_clause = if cursor.is_some() { " AND (r.deadline_ms, i.id) > (?2, ?3)" } else { "" },
        limit_param = if cursor.is_some() { 4 } else { 2 },
    );
    let mut statement = conn.prepare(&sql)?;
    let rows: Vec<(Item, i64)> = if let Some((sort_value, id)) = cursor {
        statement
            .query_map(params![now_ms, sort_value, id.to_string(), i64::from(limit) + 1], item_with_extra_from_row)?
            .collect::<Result<_, _>>()?
    } else {
        statement
            .query_map(params![now_ms, i64::from(limit) + 1], item_with_extra_from_row)?
            .collect::<Result<_, _>>()?
    };

    let has_more = rows.len() as u32 > limit;
    let mut rows = rows;
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
pub(crate) fn search(conn: &Connection, query: &SearchQuery) -> CoreResult<Page<ItemView>> {
    text::validate_note_text(&query.text)?;
    let limit = validate_limit(query.limit)?;
    let key = text::match_key(&query.text);
    let deleted_clause = if query.include_deleted { "" } else { " AND deleted_at_ms IS NULL" };
    let match_clause = if query.exact { "match_key = ?1" } else { "instr(match_key, ?1) > 0" };
    let where_clause = format!("{match_clause}{deleted_clause}");

    let total_count: i64 =
        conn.query_row(&format!("SELECT COUNT(*) FROM items WHERE {where_clause}"), [&key], |row| row.get(0))?;
    let total_count = total_count as u64;

    let cursor = query.cursor.as_deref().map(decode_cursor).transpose()?;
    let sql = format!(
        "SELECT {ITEM_COLUMNS} FROM items WHERE {where_clause}{cursor_clause}
         ORDER BY created_at_ms DESC, id DESC LIMIT ?{limit_param}",
        cursor_clause = if cursor.is_some() { " AND (created_at_ms, id) < (?2, ?3)" } else { "" },
        limit_param = if cursor.is_some() { 4 } else { 2 },
    );
    let mut statement = conn.prepare(&sql)?;
    let rows: Vec<Item> = if let Some((sort_value, id)) = cursor {
        statement
            .query_map(params![key, sort_value, id.to_string(), i64::from(limit) + 1], item_from_row)?
            .collect::<Result<_, _>>()?
    } else {
        statement.query_map(params![key, i64::from(limit) + 1], item_from_row)?.collect::<Result<_, _>>()?
    };
    paginate(conn, rows, limit, total_count, |item| item.created_at_ms)
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
