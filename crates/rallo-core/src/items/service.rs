use super::model::{Item, ItemStatus, ListFilter};
use super::repository;
use crate::shared::errors::CoreResult;
use crate::shared::{ids, text};
use crate::storage::database::{Store, bump_revision};

/// Default and maximum page size for listings.
pub const DEFAULT_PAGE_SIZE: u32 = 50;

impl Store {
    /// Durably stores a new open note and returns its committed snapshot.
    pub fn create_note(&mut self, note_text: &str) -> CoreResult<Item> {
        let note_text = text::validate_note_text(note_text)?;
        let now = self.now_ms();
        let id = ids::new_id();
        let item = Item {
            short_key: ids::short_key(&id),
            id,
            text: note_text.to_owned(),
            status: ItemStatus::Open,
            created_at_ms: now,
            updated_at_ms: now,
            completed_at_ms: None,
            deleted_at_ms: None,
            revision: 1,
        };
        let tx = self.write_tx()?;
        repository::insert(&tx, &item, &text::match_key(note_text))?;
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(item)
    }

    pub fn list_items(&self, filter: ListFilter, limit: u32) -> CoreResult<Vec<Item>> {
        repository::list(self.conn(), filter, limit.clamp(1, DEFAULT_PAGE_SIZE))
    }
}
