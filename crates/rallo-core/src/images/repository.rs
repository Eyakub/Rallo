//! The `attachments` table (0018).

use rusqlite::types::Type;
use rusqlite::{Connection, OptionalExtension, Row, params};
use uuid::Uuid;

use super::files::{NewImage, file_name};
use crate::shared::errors::CoreResult;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ImageRow {
    pub id: Uuid,
    pub item_id: Uuid,
    pub file_name: String,
    pub mime_type: String,
    pub byte_size: i64,
    pub position: i64,
    pub created_at_ms: i64,
}

const COLUMNS: &str = "id, item_id, file_name, mime_type, byte_size, position, created_at_ms";

fn uuid(row: &Row<'_>, index: usize) -> rusqlite::Result<Uuid> {
    let text: String = row.get(index)?;
    Uuid::parse_str(&text)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(index, Type::Text, Box::new(error)))
}

fn image_row(row: &Row<'_>) -> rusqlite::Result<ImageRow> {
    Ok(ImageRow {
        id: uuid(row, 0)?,
        item_id: uuid(row, 1)?,
        file_name: row.get(2)?,
        mime_type: row.get(3)?,
        byte_size: row.get(4)?,
        position: row.get(5)?,
        created_at_ms: row.get(6)?,
    })
}

/// Appends `images` after the note's current last position.
pub(crate) fn insert(conn: &Connection, item_id: Uuid, images: &[NewImage<'_>], now: i64) -> CoreResult<()> {
    let next: i64 = conn.query_row(
        "SELECT COALESCE(MAX(position), -1) + 1 FROM attachments WHERE item_id = ?1",
        [item_id.to_string()],
        |row| row.get(0),
    )?;
    for (offset, image) in images.iter().enumerate() {
        conn.execute(
            "INSERT INTO attachments (id, item_id, file_name, mime_type, byte_size, position, created_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                image.id.to_string(),
                item_id.to_string(),
                file_name(image.id, image.kind),
                image.kind.mime_type(),
                image.bytes.len() as i64,
                next + offset as i64,
                now,
            ],
        )?;
    }
    Ok(())
}

pub(crate) fn for_item(conn: &Connection, item_id: Uuid) -> CoreResult<Vec<ImageRow>> {
    let mut statement =
        conn.prepare_cached(&format!("SELECT {COLUMNS} FROM attachments WHERE item_id = ?1 ORDER BY position"))?;
    let rows = statement.query_map([item_id.to_string()], image_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub(crate) fn exists(conn: &Connection, image_id: Uuid) -> bool {
    conn.query_row("SELECT 1 FROM attachments WHERE id = ?1", [image_id.to_string()], |_| Ok(())).is_ok()
}

pub(crate) fn count(conn: &Connection, item_id: Uuid) -> CoreResult<usize> {
    let count: i64 =
        conn.query_row("SELECT COUNT(*) FROM attachments WHERE item_id = ?1", [item_id.to_string()], |row| row.get(0))?;
    Ok(count as usize)
}

pub(crate) fn delete_one(conn: &Connection, item_id: Uuid, image_id: Uuid) -> CoreResult<Option<ImageRow>> {
    let row = conn
        .query_row(
            &format!("SELECT {COLUMNS} FROM attachments WHERE item_id = ?1 AND id = ?2"),
            params![item_id.to_string(), image_id.to_string()],
            image_row,
        )
        .optional()?;
    if row.is_some() {
        conn.execute("DELETE FROM attachments WHERE id = ?1", [image_id.to_string()])?;
    }
    Ok(row)
}

/// Images of notes deleted at or before `cutoff_ms` (the 30-day sweep).
pub(crate) fn of_items_deleted_before(conn: &Connection, cutoff_ms: i64) -> CoreResult<Vec<ImageRow>> {
    let mut statement = conn.prepare(&format!(
        "SELECT {} FROM attachments a JOIN items i ON i.id = a.item_id
         WHERE i.deleted_at_ms IS NOT NULL AND i.deleted_at_ms <= ?1",
        COLUMNS.split(", ").map(|column| format!("a.{column}")).collect::<Vec<_>>().join(", ")
    ))?;
    let rows = statement.query_map([cutoff_ms], image_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

pub(crate) fn delete_ids(conn: &Connection, ids: &[Uuid]) -> CoreResult<()> {
    for id in ids {
        conn.execute("DELETE FROM attachments WHERE id = ?1", [id.to_string()])?;
    }
    Ok(())
}

pub(crate) fn all(conn: &Connection) -> CoreResult<Vec<ImageRow>> {
    let mut statement = conn.prepare(&format!("SELECT {COLUMNS} FROM attachments"))?;
    let rows = statement.query_map([], image_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn insert_imported(
    conn: &Connection,
    item_id: Uuid,
    image_id: Uuid,
    kind: super::format::ImageKind,
    byte_size: i64,
    position: i64,
    created_at_ms: i64,
) -> CoreResult<()> {
    conn.execute(
        "INSERT INTO attachments (id, item_id, file_name, mime_type, byte_size, position, created_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            image_id.to_string(),
            item_id.to_string(),
            file_name(image_id, kind),
            kind.mime_type(),
            byte_size,
            position,
            created_at_ms,
        ],
    )?;
    Ok(())
}
