use rallo_core::CoreError;
use rallo_core::agents as core_agents;
use rallo_core::items::{ItemStatus as CoreItemStatus, ItemView};
use rallo_core::pet as core_pet;
use rallo_core::preferences;
use rallo_core::reminders;
use rallo_core::reminders::protocol as core_protocol;
use rallo_core::transfer::{ExportFormat, ImportConflictRecord, ImportReport};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum RalloError {
    #[error("{message}")]
    InvalidInput { code: String, message: String },
    #[error("{message}")]
    NotFound { code: String, message: String },
    #[error("{message}")]
    Storage { code: String, message: String },
    /// Ambiguous selection, a stale revision, a request-id collision, or a
    /// precondition failure. The structured detail stays on the Rust side for
    /// now; Swift gets the code and message.
    #[error("{message}")]
    Conflict { code: String, message: String },
    #[error("{message}")]
    IncompatibleSchema { found: u32, supported: u32, message: String },
}

impl From<CoreError> for RalloError {
    fn from(error: CoreError) -> Self {
        let code = error.code().as_str().to_owned();
        let message = error.to_string();
        match error {
            CoreError::InvalidInput { .. } => Self::InvalidInput { code, message },
            CoreError::NotFound { .. } => Self::NotFound { code, message },
            CoreError::Storage { .. } => Self::Storage { code, message },
            CoreError::Conflict { .. } => Self::Conflict { code, message },
            CoreError::IncompatibleSchema { found, supported } => {
                Self::IncompatibleSchema { found, supported, message }
            }
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CoreInfo {
    pub core_version: String,
    pub schema_version: u32,
    pub json_contract_version: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ItemStatus {
    Open,
    Done,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ItemSnapshot {
    pub id: String,
    pub display_id: String,
    pub text: String,
    pub status: ItemStatus,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub completed_at_ms: Option<i64>,
    pub deleted_at_ms: Option<i64>,
    pub revision: i64,
    pub reminder: Option<ReminderSnapshot>,
}

impl From<ItemView> for ItemSnapshot {
    fn from(view: ItemView) -> Self {
        let item = view.item;
        Self {
            id: item.id.to_string(),
            display_id: view.display_id,
            status: match item.status {
                CoreItemStatus::Open => ItemStatus::Open,
                CoreItemStatus::Done => ItemStatus::Done,
            },
            text: item.text,
            created_at_ms: item.created_at_ms,
            updated_at_ms: item.updated_at_ms,
            completed_at_ms: item.completed_at_ms,
            deleted_at_ms: item.deleted_at_ms,
            revision: item.revision,
            reminder: view.reminder.map(|reminder| ReminderSnapshot {
                id: reminder.id.to_string(),
                deadline_ms: reminder.deadline_ms,
                state: reminder.state().into(),
                scheduling_state: None,
                scheduling_reason: None,
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReminderState {
    Active,
    Acknowledged,
    Cancelled,
    Completed,
    Deleted,
}

impl From<reminders::ReminderState> for ReminderState {
    fn from(state: reminders::ReminderState) -> Self {
        match state {
            reminders::ReminderState::Active => Self::Active,
            reminders::ReminderState::Acknowledged => Self::Acknowledged,
            reminders::ReminderState::Cancelled => Self::Cancelled,
            reminders::ReminderState::Completed => Self::Completed,
            reminders::ReminderState::Deleted => Self::Deleted,
        }
    }
}

/// Scheduling fields come from the core's status computation (e.g.
/// "pending"/"awaiting_app"); Swift displays them and never derives them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReminderSnapshot {
    pub id: String,
    pub deadline_ms: i64,
    pub state: ReminderState,
    pub scheduling_state: Option<String>,
    pub scheduling_reason: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PetVisibility {
    Visible,
    Hidden,
}

impl From<preferences::PetVisibility> for PetVisibility {
    fn from(value: preferences::PetVisibility) -> Self {
        match value {
            preferences::PetVisibility::Visible => Self::Visible,
            preferences::PetVisibility::Hidden => Self::Hidden,
        }
    }
}

impl From<PetVisibility> for preferences::PetVisibility {
    fn from(value: PetVisibility) -> Self {
        match value {
            PetVisibility::Visible => Self::Visible,
            PetVisibility::Hidden => Self::Hidden,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct PetPlacement {
    pub x: f64,
    pub y: f64,
}

impl From<preferences::PetPlacement> for PetPlacement {
    fn from(value: preferences::PetPlacement) -> Self {
        Self { x: value.x, y: value.y }
    }
}

impl From<PetPlacement> for preferences::PetPlacement {
    fn from(value: PetPlacement) -> Self {
        Self { x: value.x, y: value.y }
    }
}

// --- 0005 notification protocol -------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NotificationAuthorization {
    NotDetermined,
    Denied,
    Authorized,
    Provisional,
    Ephemeral,
}

impl From<NotificationAuthorization> for core_protocol::NotificationAuthorization {
    fn from(value: NotificationAuthorization) -> Self {
        match value {
            NotificationAuthorization::NotDetermined => Self::NotDetermined,
            NotificationAuthorization::Denied => Self::Denied,
            NotificationAuthorization::Authorized => Self::Authorized,
            NotificationAuthorization::Provisional => Self::Provisional,
            NotificationAuthorization::Ephemeral => Self::Ephemeral,
        }
    }
}

impl From<core_protocol::NotificationAuthorization> for NotificationAuthorization {
    fn from(value: core_protocol::NotificationAuthorization) -> Self {
        match value {
            core_protocol::NotificationAuthorization::NotDetermined => Self::NotDetermined,
            core_protocol::NotificationAuthorization::Denied => Self::Denied,
            core_protocol::NotificationAuthorization::Authorized => Self::Authorized,
            core_protocol::NotificationAuthorization::Provisional => Self::Provisional,
            core_protocol::NotificationAuthorization::Ephemeral => Self::Ephemeral,
        }
    }
}

/// One request Swift observed in `UNUserNotificationCenter`; `reminder_id`
/// and `generation` come from the request's `userInfo`, `None` if missing or
/// unparsable. `trigger_ms` is `None` for a delivered request.
#[derive(Debug, Clone, uniffi::Record)]
pub struct NativeRequest {
    pub identifier: String,
    pub reminder_id: Option<String>,
    pub generation: Option<i64>,
    pub trigger_ms: Option<i64>,
}

impl From<NativeRequest> for core_protocol::NativeRequest {
    fn from(value: NativeRequest) -> Self {
        Self {
            identifier: value.identifier,
            reminder_id: value.reminder_id.and_then(|id| uuid::Uuid::parse_str(&id).ok()),
            generation: value.generation,
            trigger_ms: value.trigger_ms,
        }
    }
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct CleanupPlan {
    pub remove_pending: Vec<String>,
    pub remove_delivered: Vec<String>,
}

impl From<core_protocol::CleanupPlan> for CleanupPlan {
    fn from(value: core_protocol::CleanupPlan) -> Self {
        Self { remove_pending: value.remove_pending, remove_delivered: value.remove_delivered }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum PlatformWork {
    Schedule {
        intent_id: i64,
        reminder_id: String,
        item_id: String,
        generation: i64,
        deadline_ms: i64,
        identifier: String,
        title: String,
        body: String,
    },
    Cancel {
        intent_id: i64,
        reminder_id: String,
        generation: i64,
        identifier: String,
    },
}

impl From<core_protocol::PlatformWork> for PlatformWork {
    fn from(value: core_protocol::PlatformWork) -> Self {
        match value {
            core_protocol::PlatformWork::Schedule {
                intent_id,
                reminder_id,
                item_id,
                generation,
                deadline_ms,
                identifier,
                title,
                body,
            } => Self::Schedule {
                intent_id,
                reminder_id: reminder_id.to_string(),
                item_id: item_id.to_string(),
                generation,
                deadline_ms,
                identifier,
                title,
                body,
            },
            core_protocol::PlatformWork::Cancel { intent_id, reminder_id, generation, identifier } => {
                Self::Cancel { intent_id, reminder_id: reminder_id.to_string(), generation, identifier }
            }
        }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum NextWork {
    Work(PlatformWork),
    Idle { next_wake_at_ms: Option<i64> },
}

impl From<core_protocol::NextWork> for NextWork {
    fn from(value: core_protocol::NextWork) -> Self {
        match value {
            core_protocol::NextWork::Work(work) => Self::Work(work.into()),
            core_protocol::NextWork::Idle { next_wake_at_ms } => Self::Idle { next_wake_at_ms },
        }
    }
}

/// Proof that `begin_platform_attempt` marked an intent `attempting`;
/// round-trips through Swift to `finish_platform_attempt`.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct AttemptToken {
    pub intent_id: i64,
    pub generation: i64,
    pub attempt: i64,
}

impl From<core_protocol::AttemptToken> for AttemptToken {
    fn from(value: core_protocol::AttemptToken) -> Self {
        Self { intent_id: value.intent_id, generation: value.generation, attempt: value.attempt }
    }
}

impl From<AttemptToken> for core_protocol::AttemptToken {
    fn from(value: AttemptToken) -> Self {
        Self { intent_id: value.intent_id, generation: value.generation, attempt: value.attempt }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum BeginOutcome {
    Started(AttemptToken),
    Superseded,
}

impl From<core_protocol::BeginOutcome> for BeginOutcome {
    fn from(value: core_protocol::BeginOutcome) -> Self {
        match value {
            core_protocol::BeginOutcome::Started(token) => Self::Started(token.into()),
            core_protocol::BeginOutcome::Superseded => Self::Superseded,
        }
    }
}

/// What Swift observed after attempting a native effect.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum NativeOutcome {
    Accepted { readback_trigger_ms: i64 },
    Removed,
    NotConfirmed,
    TransientFailure { code: String },
    PermissionDenied,
}

impl From<NativeOutcome> for core_protocol::NativeOutcome {
    fn from(value: NativeOutcome) -> Self {
        match value {
            NativeOutcome::Accepted { readback_trigger_ms } => Self::Accepted { readback_trigger_ms },
            NativeOutcome::Removed => Self::Removed,
            NativeOutcome::NotConfirmed => Self::NotConfirmed,
            NativeOutcome::TransientFailure { code } => Self::TransientFailure { code },
            NativeOutcome::PermissionDenied => Self::PermissionDenied,
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Finished {
    pub applied: bool,
    pub superseded: bool,
    pub retry_at_ms: Option<i64>,
}

impl From<core_protocol::Finished> for Finished {
    fn from(value: core_protocol::Finished) -> Self {
        Self { applied: value.applied, superseded: value.superseded, retry_at_ms: value.retry_at_ms }
    }
}

/// A tapped notification action's category identifier.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum NotificationAction {
    Done,
    Snooze10m,
}

impl From<NotificationAction> for core_protocol::NotificationAction {
    fn from(value: NotificationAction) -> Self {
        match value {
            NotificationAction::Done => Self::Done,
            NotificationAction::Snooze10m => Self::Snooze10m,
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum StaleReason {
    Changed,
    Deleted,
    Missing,
}

impl From<core_protocol::StaleReason> for StaleReason {
    fn from(value: core_protocol::StaleReason) -> Self {
        match value {
            core_protocol::StaleReason::Changed => Self::Changed,
            core_protocol::StaleReason::Deleted => Self::Deleted,
            core_protocol::StaleReason::Missing => Self::Missing,
        }
    }
}

/// Result of a tapped notification action; built in `lib.rs` (it needs a
/// `&Store` to attach scheduling status to the snapshot, like `from_view`).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ActionOutcome {
    Applied(ItemSnapshot),
    Stale { item: Option<ItemSnapshot>, reason: StaleReason },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TransferFormat {
    Json,
    Csv,
}

impl From<TransferFormat> for ExportFormat {
    fn from(format: TransferFormat) -> Self {
        match format {
            TransferFormat::Json => Self::Json,
            TransferFormat::Csv => Self::Csv,
        }
    }
}

impl From<ExportFormat> for TransferFormat {
    fn from(format: ExportFormat) -> Self {
        match format {
            ExportFormat::Json => Self::Json,
            ExportFormat::Csv => Self::Csv,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExportResult {
    pub items: u64,
    pub path: String,
}

/// Where a conflicting record is in the file; never its note text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportConflict {
    pub id: Option<String>,
    pub line: Option<u64>,
    pub index: Option<u64>,
    pub reason: String,
}

impl From<ImportConflictRecord> for ImportConflict {
    fn from(record: ImportConflictRecord) -> Self {
        Self { id: record.id.map(|id| id.to_string()), line: record.line, index: record.index, reason: record.reason }
    }
}

/// A dry run (`applied == false`) or the committed result of an import.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ImportSummary {
    pub format: TransferFormat,
    pub total_records: u64,
    pub new: u64,
    pub identical: u64,
    pub conflicts: Vec<ImportConflict>,
    pub conflict_total: u64,
    pub warnings: Vec<String>,
    pub applied: bool,
    pub backup_path: Option<String>,
}

impl From<ImportReport> for ImportSummary {
    fn from(report: ImportReport) -> Self {
        Self {
            format: report.format.into(),
            total_records: report.total_records,
            new: report.new,
            identical: report.identical,
            conflicts: report.conflicts.into_iter().map(Into::into).collect(),
            conflict_total: report.conflict_total,
            warnings: report.warnings,
            applied: report.applied,
            backup_path: report.backup_path.map(|path| path.display().to_string()),
        }
    }
}

// --- Agent attention (0007, 0009) --------------------------------------------

/// One Claude Code/Codex/Grok session waiting on the user, for the panel's
/// "Agents" section. `place` is the last two folders of the agent's working
/// directory ("~" for home); `focus` an opaque terminal target for jumping
/// to the exact pane ("cmux:<workspace>:<panel>" or "tty:/dev/ttysN").
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AgentSessionSnapshot {
    pub agent: String,
    pub session_id: String,
    pub state: String,
    pub place: Option<String>,
    pub detail: Option<String>,
    pub app_path: Option<String>,
    pub app_pid: Option<i64>,
    pub focus: Option<String>,
    pub updated_at_ms: i64,
}

impl From<core_agents::AgentSession> for AgentSessionSnapshot {
    fn from(value: core_agents::AgentSession) -> Self {
        Self {
            agent: value.agent.as_str().to_owned(),
            session_id: value.session_id,
            state: value.state.as_str().to_owned(),
            place: value.place,
            detail: value.detail,
            app_path: value.app_path,
            app_pid: value.app_pid,
            focus: value.focus,
            updated_at_ms: value.updated_at_ms,
        }
    }
}

/// One ClickUp conversation waiting on the user, pushed by the app after it
/// polls ClickUp (0010).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalWaitingInput {
    pub id: String,
    pub who: String,
    pub group: bool,
    pub app_path: Option<String>,
    pub focus: Option<String>,
    pub latest_at_ms: i64,
}

impl From<ExternalWaitingInput> for core_agents::ExternalWaiting {
    fn from(value: ExternalWaitingInput) -> Self {
        Self {
            id: value.id,
            who: value.who,
            group: value.group,
            app_path: value.app_path,
            focus: value.focus,
            latest_at_ms: value.latest_at_ms,
        }
    }
}

// --- Pet reducer (plan §2; 0006) ------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PetSnapshot {
    pub open_count: u32,
    pub due_count: u32,
    pub next_due_at_ms: Option<i64>,
    pub completion_seq: i64,
    pub save_seq: i64,
    /// Fresh (≤24h) `waiting` agent sessions (0007).
    pub agents_waiting: u32,
    pub agent_waiting_seq: i64,
}

impl From<core_pet::PetSnapshot> for PetSnapshot {
    fn from(value: core_pet::PetSnapshot) -> Self {
        Self {
            open_count: value.open_count,
            due_count: value.due_count,
            next_due_at_ms: value.next_due_at_ms,
            completion_seq: value.completion_seq,
            save_seq: value.save_seq,
            agents_waiting: value.agents_waiting,
            agent_waiting_seq: value.agent_waiting_seq,
        }
    }
}

impl From<PetSnapshot> for core_pet::PetSnapshot {
    fn from(value: PetSnapshot) -> Self {
        Self {
            open_count: value.open_count,
            due_count: value.due_count,
            next_due_at_ms: value.next_due_at_ms,
            completion_seq: value.completion_seq,
            save_seq: value.save_seq,
            agents_waiting: value.agents_waiting,
            agent_waiting_seq: value.agent_waiting_seq,
        }
    }
}

/// Everything the reducer needs besides the domain snapshot: visibility,
/// accessibility settings, and what Swift has already shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PetInputs {
    pub visible: bool,
    pub reduced_motion: bool,
    pub animations_paused: bool,
    pub snapshot: PetSnapshot,
    pub seen_completion_seq: i64,
    pub seen_save_seq: i64,
    /// `agent_waiting_seq` last acknowledged by a played `Attention` (0007).
    pub seen_agent_waiting_seq: i64,
    pub was_due: bool,
}

impl From<PetInputs> for core_pet::PetInputs {
    fn from(value: PetInputs) -> Self {
        Self {
            visible: value.visible,
            reduced_motion: value.reduced_motion,
            animations_paused: value.animations_paused,
            snapshot: value.snapshot.into(),
            seen_completion_seq: value.seen_completion_seq,
            seen_save_seq: value.seen_save_seq,
            seen_agent_waiting_seq: value.seen_agent_waiting_seq,
            was_due: value.was_due,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PetPose {
    Hidden,
    Sleeping,
    Idle,
    Due,
}

impl From<core_pet::PetPose> for PetPose {
    fn from(value: core_pet::PetPose) -> Self {
        match value {
            core_pet::PetPose::Hidden => Self::Hidden,
            core_pet::PetPose::Sleeping => Self::Sleeping,
            core_pet::PetPose::Idle => Self::Idle,
            core_pet::PetPose::Due => Self::Due,
        }
    }
}

/// A one-shot transition Swift plays once, then recomputes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PetEvent {
    None,
    Attention,
    Celebrate,
    Acknowledge,
}

impl From<core_pet::PetEvent> for PetEvent {
    fn from(value: core_pet::PetEvent) -> Self {
        match value {
            core_pet::PetEvent::None => Self::None,
            core_pet::PetEvent::Attention => Self::Attention,
            core_pet::PetEvent::Celebrate => Self::Celebrate,
            core_pet::PetEvent::Acknowledge => Self::Acknowledge,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PetDecision {
    pub pose: PetPose,
    pub event: PetEvent,
    pub animate: bool,
    pub ambient: bool,
    pub accessibility_label: String,
}

impl From<core_pet::PetDecision> for PetDecision {
    fn from(value: core_pet::PetDecision) -> Self {
        Self {
            pose: value.pose.into(),
            event: value.event.into(),
            animate: value.animate,
            ambient: value.ambient,
            accessibility_label: value.accessibility_label,
        }
    }
}
