//! Typed, versioned user preferences shared by the CLI and the app.

use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::shared::errors::CoreResult;
use crate::storage::database::{Store, bump_revision};

const PET_VISIBILITY: &str = "pet.visibility";
const PET_PLACEMENT: &str = "pet.placement";
const ONBOARDING_COMPLETED: &str = "onboarding.completed";
const NOTIFICATIONS_PREVIEW_TEXT: &str = "notifications.preview_text";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PetVisibility {
    Visible,
    Hidden,
}

/// Pet origin in global AppKit screen coordinates (points, bottom-left origin).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct PetPlacement {
    pub x: f64,
    pub y: f64,
}

impl Store {
    fn read_preference<T: for<'de> Deserialize<'de>>(&self, key: &str) -> CoreResult<Option<T>> {
        let raw: Option<String> = self
            .conn()
            .query_row("SELECT value FROM preferences WHERE key = ?1", [key], |row| row.get(0))
            .optional()?;
        // A value this build cannot parse is treated as unset rather than fatal.
        Ok(raw.and_then(|raw| serde_json::from_str(&raw).ok()))
    }

    /// Writes a preference; bumps the global revision only if the value changed.
    fn write_preference<T: Serialize>(&mut self, key: &str, value: Option<&T>) -> CoreResult<bool> {
        let now = self.now_ms();
        let encoded = value.map(|value| serde_json::to_string(value).expect("preference values serialize"));
        let tx = self.write_tx()?;
        let current: Option<String> =
            tx.query_row("SELECT value FROM preferences WHERE key = ?1", [key], |row| row.get(0)).optional()?;
        if current == encoded {
            return Ok(false);
        }
        match &encoded {
            Some(encoded) => tx.execute(
                "INSERT INTO preferences (key, value, revision, updated_at_ms) VALUES (?1, ?2, 1, ?3)
                 ON CONFLICT (key) DO UPDATE SET value = excluded.value, revision = revision + 1,
                                                 updated_at_ms = excluded.updated_at_ms",
                params![key, encoded, now],
            )?,
            None => tx.execute("DELETE FROM preferences WHERE key = ?1", [key])?,
        };
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(true)
    }

    /// `None` means the pet has never been introduced (first interactive launch).
    pub fn pet_visibility(&self) -> CoreResult<Option<PetVisibility>> {
        self.read_preference(PET_VISIBILITY)
    }

    pub fn set_pet_visibility(&mut self, visibility: PetVisibility) -> CoreResult<bool> {
        self.write_preference(PET_VISIBILITY, Some(&visibility))
    }

    pub fn pet_placement(&self) -> CoreResult<Option<PetPlacement>> {
        self.read_preference(PET_PLACEMENT)
    }

    /// `None` resets to the default position.
    pub fn set_pet_placement(&mut self, placement: Option<PetPlacement>) -> CoreResult<bool> {
        self.write_preference(PET_PLACEMENT, placement.as_ref())
    }

    pub fn onboarding_completed(&self) -> CoreResult<bool> {
        Ok(self.read_preference(ONBOARDING_COMPLETED)?.unwrap_or(false))
    }

    pub fn set_onboarding_completed(&mut self) -> CoreResult<bool> {
        self.write_preference(ONBOARDING_COMPLETED, Some(&true))
    }

    /// Whether a text edit refreshes an active reminder's notification
    /// payload (0003 §3 `edit`). Off by default: previews can leak note text
    /// into a system notification.
    pub fn preview_text_enabled(&self) -> CoreResult<bool> {
        Ok(self.read_preference(NOTIFICATIONS_PREVIEW_TEXT)?.unwrap_or(false))
    }

    pub fn set_preview_text_enabled(&mut self, enabled: bool) -> CoreResult<bool> {
        self.write_preference(NOTIFICATIONS_PREVIEW_TEXT, Some(&enabled))
    }
}
