use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};
use uuid::Uuid;

use super::model::{Folder, FolderCount, FolderRef, FolderSelector};
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::shared::text;

const COLUMNS: &str = "id, name, created_at_ms, updated_at_ms, revision";

fn folder_from_row(row: &Row<'_>) -> rusqlite::Result<Folder> {
    let id: String = row.get(0)?;
    Ok(Folder {
        id: Uuid::parse_str(&id)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))?,
        name: row.get(1)?,
        created_at_ms: row.get(2)?,
        updated_at_ms: row.get(3)?,
        revision: row.get(4)?,
    })
}

pub(crate) fn get(conn: &Connection, id: Uuid) -> CoreResult<Option<Folder>> {
    Ok(conn
        .query_row(&format!("SELECT {COLUMNS} FROM folders WHERE id = ?1"), [id.to_string()], folder_from_row)
        .optional()?)
}

pub(crate) fn by_key(conn: &Connection, name_key: &str) -> CoreResult<Option<Folder>> {
    Ok(conn
        .query_row(&format!("SELECT {COLUMNS} FROM folders WHERE name_key = ?1"), [name_key], folder_from_row)
        .optional()?)
}

/// Every folder, alphabetical by `name_key` (0019 §3).
pub(crate) fn all(conn: &Connection) -> CoreResult<Vec<Folder>> {
    let mut statement = conn.prepare(&format!("SELECT {COLUMNS} FROM folders ORDER BY name_key"))?;
    Ok(statement.query_map([], folder_from_row)?.collect::<Result<_, _>>()?)
}

pub(crate) fn insert(conn: &Connection, folder: &Folder, name_key: &str) -> CoreResult<()> {
    conn.execute(
        "INSERT INTO folders (id, name, name_key, created_at_ms, updated_at_ms, revision)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            folder.id.to_string(),
            folder.name,
            name_key,
            folder.created_at_ms,
            folder.updated_at_ms,
            folder.revision
        ],
    )?;
    Ok(())
}

pub(crate) fn rename(tx: &Transaction<'_>, id: Uuid, name: &str, name_key: &str, now_ms: i64) -> CoreResult<()> {
    tx.execute(
        "UPDATE folders SET name = ?2, name_key = ?3, updated_at_ms = ?4, revision = revision + 1 WHERE id = ?1",
        params![id.to_string(), name, name_key, now_ms],
    )?;
    Ok(())
}

pub(crate) fn delete_row(tx: &Transaction<'_>, id: Uuid) -> CoreResult<()> {
    tx.execute("DELETE FROM folders WHERE id = ?1", [id.to_string()])?;
    Ok(())
}

/// `{id, name}` for an item's JSON; `None` for Notes.
pub(crate) fn folder_ref(conn: &Connection, id: Option<Uuid>) -> CoreResult<Option<FolderRef>> {
    let Some(id) = id else { return Ok(None) };
    Ok(get(conn, id)?.map(|folder| FolderRef { id: folder.id, name: folder.name }))
}

/// A selector to its folder: `None` is Notes. An unknown name or id is
/// `FOLDER_NOT_FOUND`; the name's message lists the folders there are (0019 §3).
pub(crate) fn resolve(conn: &Connection, selector: &FolderSelector) -> CoreResult<Option<Folder>> {
    match selector {
        FolderSelector::Notes => Ok(None),
        FolderSelector::Id(id) => get(conn, *id)?
            .map(Some)
            .ok_or_else(|| CoreError::not_found(ErrorCode::FolderNotFound, "no folder has that id")),
        FolderSelector::Name(name) => {
            // A name that could never be a folder just matches none.
            let key = text::match_key(name);
            match by_key(conn, &key)? {
                Some(folder) => Ok(Some(folder)),
                None => {
                    let mut names = vec!["Notes".to_owned()];
                    names.extend(all(conn)?.into_iter().map(|folder| folder.name));
                    Err(CoreError::not_found(
                        ErrorCode::FolderNotFound,
                        format!(
                            "no folder named \u{201c}{}\u{201d}; the folders are: {}",
                            name.trim(),
                            names.join(", ")
                        ),
                    ))
                }
            }
        }
    }
}

/// Notes first, then every folder alphabetically, each with its open,
/// nondeleted count (0019 §1, §6) and its open-plus-done count (§9).
pub(crate) fn counts(conn: &Connection) -> CoreResult<Vec<FolderCount>> {
    let (unfiled_open, unfiled_notes): (i64, i64) = conn.query_row(
        "SELECT COUNT(CASE WHEN status = 'open' THEN 1 END), COUNT(*)
         FROM items WHERE folder_id IS NULL AND deleted_at_ms IS NULL",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let mut counts =
        vec![FolderCount { folder: None, note_count: unfiled_notes as u64, open_count: unfiled_open as u64 }];
    let mut statement = conn.prepare(
        "SELECT f.id, f.name, f.created_at_ms, f.updated_at_ms, f.revision,
                COUNT(CASE WHEN i.status = 'open' THEN 1 END), COUNT(i.id)
         FROM folders f
         LEFT JOIN items i ON i.folder_id = f.id AND i.deleted_at_ms IS NULL
         GROUP BY f.id ORDER BY f.name_key",
    )?;
    let rows =
        statement.query_map([], |row| Ok((folder_from_row(row)?, row.get::<_, i64>(5)?, row.get::<_, i64>(6)?)))?;
    for row in rows {
        let (folder, open, notes) = row?;
        counts.push(FolderCount { folder: Some(folder), note_count: notes as u64, open_count: open as u64 });
    }
    Ok(counts)
}

/// Nondeleted notes (open or done) in a folder: what makes it "hold notes" (0019 §5).
pub(crate) fn nondeleted_ids(conn: &Connection, id: Uuid) -> CoreResult<Vec<Uuid>> {
    let mut statement =
        conn.prepare("SELECT id FROM items WHERE folder_id = ?1 AND deleted_at_ms IS NULL ORDER BY created_at_ms, id")?;
    let ids: Vec<String> = statement.query_map([id.to_string()], |row| row.get(0))?.collect::<Result<_, _>>()?;
    ids.iter()
        .map(|id| Uuid::parse_str(id).map_err(|e| CoreError::storage(format!("stored item id is invalid: {e}"))))
        .collect()
}

/// Clears `folder_id` on every item in the folder, deleted ones included
/// (0019 §5), bumping each row's revision. Returns how many rows changed.
pub(crate) fn clear_items(tx: &Transaction<'_>, id: Uuid, now_ms: i64) -> CoreResult<u64> {
    let changed = tx.execute(
        "UPDATE items SET folder_id = NULL, updated_at_ms = ?2, revision = revision + 1 WHERE folder_id = ?1",
        params![id.to_string(), now_ms],
    )?;
    Ok(changed as u64)
}
