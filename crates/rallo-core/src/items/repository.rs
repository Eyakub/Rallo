use rusqlite::{Connection, Row, params};
use uuid::Uuid;

use super::model::{Item, ItemStatus, ListFilter};
use crate::shared::errors::{CoreError, CoreResult};

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

pub(crate) fn list(conn: &Connection, filter: ListFilter, limit: u32) -> CoreResult<Vec<Item>> {
    let sql = match filter {
        ListFilter::Open => format!(
            "SELECT {ITEM_COLUMNS} FROM items INDEXED BY items_open_by_created
             WHERE deleted_at_ms IS NULL AND status = 'open'
             ORDER BY created_at_ms DESC, id DESC LIMIT ?1"
        ),
    };
    let mut statement = conn.prepare_cached(&sql)?;
    let rows = statement.query_map([limit], item_from_row)?;
    rows.collect::<Result<_, _>>().map_err(CoreError::from)
}
