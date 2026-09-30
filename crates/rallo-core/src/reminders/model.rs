use serde::Serialize;
use serde::ser::SerializeStruct;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

/// Derived reminder state (0003 §2); not a stored column.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReminderState {
    Active,
    Acknowledged,
    Cancelled,
    Completed,
    Deleted,
}

impl ReminderState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Acknowledged => "acknowledged",
            Self::Cancelled => "cancelled",
            Self::Completed => "completed",
            Self::Deleted => "deleted",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputKind {
    Relative,
    Absolute,
}

impl InputKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Relative => "relative",
            Self::Absolute => "absolute",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "relative" => Some(Self::Relative),
            "absolute" => Some(Self::Absolute),
            _ => None,
        }
    }
}

/// Why a reminder is currently disabled. Internal: `ReminderState` is the
/// JSON-facing projection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DisabledReason {
    Acknowledged,
    Cancelled,
    ItemCompleted,
    ItemDeleted,
    Imported,
}

impl DisabledReason {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Acknowledged => "acknowledged",
            Self::Cancelled => "cancelled",
            Self::ItemCompleted => "item_completed",
            Self::ItemDeleted => "item_deleted",
            Self::Imported => "imported",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "acknowledged" => Some(Self::Acknowledged),
            "cancelled" => Some(Self::Cancelled),
            "item_completed" => Some(Self::ItemCompleted),
            "item_deleted" => Some(Self::ItemDeleted),
            "imported" => Some(Self::Imported),
            _ => None,
        }
    }
}

/// One item's one-time reminder (at most one per item; see the `reminders`
/// table's UNIQUE constraint).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reminder {
    pub id: Uuid,
    pub item_id: Uuid,
    pub deadline_ms: i64,
    pub time_input: String,
    pub input_kind: InputKind,
    pub input_offset_seconds: Option<i32>,
    pub enabled: bool,
    pub(crate) disabled_reason: Option<DisabledReason>,
    pub acknowledged_at_ms: Option<i64>,
    pub generation: i64,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

impl Reminder {
    pub fn state(&self) -> ReminderState {
        if self.enabled {
            return ReminderState::Active;
        }
        match self.disabled_reason {
            Some(DisabledReason::Acknowledged) => ReminderState::Acknowledged,
            Some(DisabledReason::Cancelled) => ReminderState::Cancelled,
            Some(DisabledReason::ItemCompleted) => ReminderState::Completed,
            Some(DisabledReason::ItemDeleted) => ReminderState::Deleted,
            // Import predates M1; treat as an ordinary cancellation until an
            // importer lands and gives this its own derived state.
            Some(DisabledReason::Imported) => ReminderState::Cancelled,
            None => unreachable!("schema CHECK: enabled = 0 implies disabled_reason IS NOT NULL"),
        }
    }
}

fn rfc3339_utc_ms(ms: i64) -> String {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(ms) * 1_000_000)
        .expect("stored deadlines stay within RFC 3339's representable range")
        .format(&Rfc3339)
        .expect("RFC 3339 formatting cannot fail for a valid OffsetDateTime")
}

/// JSON shape per 0003 §11: `id`, `deadline_ms`/`deadline`, `time_input`,
/// `input_kind`, derived `state`, `acknowledged_at_ms`, `generation`. Internal
/// fields (`item_id`, `enabled`, `disabled_reason`, offsets, timestamps) never
/// cross the boundary directly.
impl Serialize for Reminder {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut out = serializer.serialize_struct("Reminder", 8)?;
        out.serialize_field("id", &self.id)?;
        out.serialize_field("deadline_ms", &self.deadline_ms)?;
        out.serialize_field("deadline", &rfc3339_utc_ms(self.deadline_ms))?;
        out.serialize_field("time_input", &self.time_input)?;
        out.serialize_field("input_kind", self.input_kind.as_str())?;
        out.serialize_field("state", self.state().as_str())?;
        out.serialize_field("acknowledged_at_ms", &self.acknowledged_at_ms)?;
        out.serialize_field("generation", &self.generation)?;
        out.end()
    }
}

/// Reported when native scheduling has not yet been confirmed (0003 §11).
/// M1 never populates `observed_at_ms`; M2 fills it from
/// `notification_observations`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct SchedulingStatus {
    pub state: &'static str,
    pub reason: &'static str,
    pub observed_at_ms: Option<i64>,
}

/// Reported when a cancel intent has not yet been confirmed applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct CancellationStatus {
    pub state: &'static str,
    pub reason: &'static str,
}
