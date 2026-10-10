//! Typed, versioned user preferences shared by the CLI and the app.

use rusqlite::{OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::reminders::repository::schedule_refresh_if_active;
use crate::shared::errors::{CoreError, CoreResult, ErrorCode};
use crate::storage::database::{Store, bump_revision};

const PET_VISIBILITY: &str = "pet.visibility";
const PET_PLACEMENT: &str = "pet.placement";
const PET_ANIMATIONS_PAUSED: &str = "pet.animations_paused";
const ONBOARDING_COMPLETED: &str = "onboarding.completed";
const NOTIFICATIONS_PREVIEW_TEXT: &str = "notifications.preview_text";
const AGENTS_NOTIFY_LONG_WAIT: &str = "agents.notify_long_wait";
const ALERTS_SETTINGS: &str = "alerts.settings";
const EYE_BREAKS_SETTINGS: &str = "eye_breaks.settings";

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

/// The alert chime (0021 §6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AlertSound {
    #[default]
    RalloChime,
    BambooKnock,
    GentleBell,
    System,
    None,
}

/// Settings › Notifications › Alerts (0021 §7, §10). Every field has a
/// default, so a value from an older or newer build still reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AlertSettings {
    pub summon: bool,
    pub sound: AlertSound,
    pub nag: bool,
    pub nag_interval_minutes: u8,
    pub nag_max_rounds: u8,
    pub glow: bool,
    pub agents: bool,
}

impl Default for AlertSettings {
    fn default() -> Self {
        Self {
            summon: true,
            sound: AlertSound::RalloChime,
            nag: true,
            nag_interval_minutes: 2,
            nag_max_rounds: 5,
            glow: false,
            agents: true,
        }
    }
}

impl AlertSettings {
    /// The FFI is a trust boundary: only the choices Settings offers.
    fn validate(&self) -> CoreResult<()> {
        if ![1, 2, 5].contains(&self.nag_interval_minutes) {
            return Err(CoreError::invalid(ErrorCode::InvalidInput, "nag interval must be 1, 2 or 5 minutes"));
        }
        if ![3, 5, 10].contains(&self.nag_max_rounds) {
            return Err(CoreError::invalid(ErrorCode::InvalidInput, "nag repeats must be 3, 5 or 10"));
        }
        Ok(())
    }
}

/// 20-20-20 eye breaks (0022 §9). Off by default.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct EyeBreakSettings {
    pub enabled: bool,
    pub interval_minutes: u8,
    pub length_seconds: u8,
    /// 0 means no warning: the break starts at once.
    pub warn_seconds: u8,
    pub allow_skip: bool,
    pub hold_on_call: bool,
}

impl Default for EyeBreakSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            interval_minutes: 20,
            length_seconds: 20,
            warn_seconds: 10,
            allow_skip: true,
            hold_on_call: true,
        }
    }
}

impl EyeBreakSettings {
    pub const INTERVAL_MINUTES: [u8; 6] = [10, 15, 20, 30, 45, 60];
    pub const LENGTH_SECONDS: [u8; 4] = [10, 20, 30, 60];
    pub const WARN_SECONDS: [u8; 4] = [0, 5, 10, 30];

    fn validate(&self) -> CoreResult<()> {
        let check = |value: u8, allowed: &[u8], what: &str| {
            if allowed.contains(&value) {
                Ok(())
            } else {
                Err(CoreError::invalid(ErrorCode::InvalidInput, format!("eye break {what} must be one of {allowed:?}")))
            }
        };
        check(self.interval_minutes, &Self::INTERVAL_MINUTES, "interval (minutes)")?;
        check(self.length_seconds, &Self::LENGTH_SECONDS, "length (seconds)")?;
        check(self.warn_seconds, &Self::WARN_SECONDS, "warning (seconds)")
    }
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
        let tx = self.write_tx()?;
        if !upsert_preference(&tx, key, value, now)? {
            return Ok(false);
        }
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

    /// Menu-bar "pause animation" (plan §"Interaction rules"). Off by
    /// default: the pet animates unless explicitly paused.
    pub fn pet_animations_paused(&self) -> CoreResult<bool> {
        Ok(self.read_preference(PET_ANIMATIONS_PAUSED)?.unwrap_or(false))
    }

    pub fn set_pet_animations_paused(&mut self, paused: bool) -> CoreResult<bool> {
        self.write_preference(PET_ANIMATIONS_PAUSED, Some(&paused))
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

    /// Menu-bar "Notify When an Agent Waits 5 Minutes" (0008). Off by
    /// default: the long-wait notification is opt-in.
    pub fn agents_notify_long_wait(&self) -> CoreResult<bool> {
        Ok(self.read_preference(AGENTS_NOTIFY_LONG_WAIT)?.unwrap_or(false))
    }

    pub fn set_agents_notify_long_wait(&mut self, enabled: bool) -> CoreResult<bool> {
        self.write_preference(AGENTS_NOTIFY_LONG_WAIT, Some(&enabled))
    }

    pub fn alert_settings(&self) -> CoreResult<AlertSettings> {
        Ok(self.read_preference(ALERTS_SETTINGS)?.unwrap_or_default())
    }

    /// A new `sound` re-registers every pending banner in the same
    /// transaction (0021 §6; build plan: preference changes that affect
    /// pending notification content queue reconciliation).
    pub fn set_alert_settings(&mut self, settings: AlertSettings) -> CoreResult<bool> {
        settings.validate()?;
        let now = self.now_ms();
        let tx = self.write_tx()?;
        let previous: AlertSettings = tx
            .query_row("SELECT value FROM preferences WHERE key = ?1", [ALERTS_SETTINGS], |row| row.get::<_, String>(0))
            .optional()?
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default();
        if !upsert_preference(&tx, ALERTS_SETTINGS, Some(&settings), now)? {
            return Ok(false);
        }
        if settings.sound != previous.sound {
            let item_ids: Vec<String> = {
                let mut statement =
                    tx.prepare("SELECT item_id FROM reminders WHERE enabled = 1 AND deadline_ms > ?1")?;
                let rows = statement.query_map([now], |row| row.get(0))?;
                rows.collect::<Result<_, _>>()?
            };
            for item_id in item_ids {
                let item_id =
                    Uuid::parse_str(&item_id).map_err(|_| CoreError::storage("reminder item_id is not a UUID"))?;
                schedule_refresh_if_active(&tx, item_id, now)?;
            }
        }
        bump_revision(&tx)?;
        tx.commit()?;
        Ok(true)
    }

    /// 0022 §9. Unset, unreadable or out-of-range stored values read as the defaults.
    pub fn eye_break_settings(&self) -> CoreResult<EyeBreakSettings> {
        Ok(self
            .read_preference::<EyeBreakSettings>(EYE_BREAKS_SETTINGS)?
            .filter(|settings| settings.validate().is_ok())
            .unwrap_or_default())
    }

    /// Rejects a value outside the listed choices (the FFI is a trust boundary).
    pub fn set_eye_break_settings(&mut self, settings: EyeBreakSettings) -> CoreResult<bool> {
        settings.validate()?;
        self.write_preference(EYE_BREAKS_SETTINGS, Some(&settings))
    }
}

/// Writes `value` (or deletes the key) inside `tx`; `Ok(false)` when it is unchanged.
fn upsert_preference<T: Serialize>(tx: &Transaction<'_>, key: &str, value: Option<&T>, now: i64) -> CoreResult<bool> {
    let encoded = value.map(|value| serde_json::to_string(value).expect("preference values serialize"));
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
    Ok(true)
}
