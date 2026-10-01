//! Agent attention (0007, 0009): sessions Claude Code/Codex hooks report
//! through `rallo agent-event`, and the read paths the pet reducer
//! (`pet::mod`) and `rallo agents` build on.
//!
//! Sessions are runtime state, not user data (0009): they live in the
//! attached `runtime` database (`<data dir>/runtime/agents.sqlite3`), which
//! is never backed up, exported, or migrated -- a layout from another version
//! is dropped and recreated. A row lasts as long as its agent process:
//! `prune_agent_sessions` removes rows whose process has gone, plus anything
//! idle for 24 h.
//!
//! Nothing here stores prompt or model text: `detail` is a tool name at most,
//! `place` the last two folders of the working directory, and `focus` an
//! opaque terminal target ("cmux:<workspace>:<panel>" or "tty:/dev/ttysN").

use rusqlite::{Connection, OptionalExtension, Row, Transaction, TransactionBehavior, params};

use crate::shared::errors::CoreResult;
use crate::storage::database::{Store, bump_revision};

const STATE_SEQ_KEY: &str = "agents.state_seq";

/// Rows not updated within this window are pruned and excluded from every
/// read (`agent_sessions`, `pet_snapshot`): a backstop for rows without a
/// known agent process.
pub(crate) const FRESH_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;

const RUNTIME_SCHEMA_VERSION: i64 = 2;
const RUNTIME_SCHEMA: &str = "
CREATE TABLE runtime.agent_sessions (
  agent            TEXT NOT NULL CHECK (agent IN ('claude', 'codex', 'clickup')),
  session_id       TEXT NOT NULL CHECK (length(session_id) BETWEEN 1 AND 200),
  state            TEXT NOT NULL CHECK (state IN ('working', 'waiting')),
  place            TEXT CHECK (place IS NULL OR length(place) <= 300),
  detail           TEXT CHECK (detail IS NULL OR length(detail) <= 120),
  app_path         TEXT CHECK (app_path IS NULL OR length(app_path) <= 4096),
  app_pid          INTEGER,
  focus            TEXT CHECK (focus IS NULL OR length(focus) <= 200),
  agent_pid        INTEGER,
  agent_started_us INTEGER,
  state_seq        INTEGER NOT NULL,
  updated_at_ms    INTEGER NOT NULL,
  PRIMARY KEY (agent, session_id)
) STRICT, WITHOUT ROWID;";

fn runtime_version(conn: &Connection) -> CoreResult<i64> {
    Ok(conn.pragma_query_value(Some("runtime"), "user_version", |row| row.get(0))?)
}

/// Creates the runtime layout, or drops and recreates one from another
/// version: its rows are disposable by design (0009).
pub(crate) fn ensure_runtime_schema(conn: &mut Connection) -> CoreResult<()> {
    if runtime_version(conn)? == RUNTIME_SCHEMA_VERSION {
        return Ok(());
    }
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    // Another process may have created it while we waited for the lock.
    if runtime_version(&tx)? != RUNTIME_SCHEMA_VERSION {
        tx.execute_batch(&format!(
            "DROP TABLE IF EXISTS runtime.agent_sessions; {RUNTIME_SCHEMA}
             PRAGMA runtime.user_version = {RUNTIME_SCHEMA_VERSION};"
        ))?;
    }
    tx.commit()?;
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentKind {
    Claude,
    Codex,
    ClickUp,
}

impl AgentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::ClickUp => "clickup",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            "clickup" => Some(Self::ClickUp),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Waiting,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Waiting => "waiting",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "working" => Some(Self::Working),
            "waiting" => Some(Self::Waiting),
            _ => None,
        }
    }
}

/// One conversation in an external service waiting on the user (0010):
/// the app polls the service and replaces that source's rows wholesale.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalWaiting {
    /// Conversation id; becomes the row's `session_id`.
    pub id: String,
    /// Display name of whoever is waiting; becomes `place`.
    pub who: String,
    /// A group conversation (`detail` = "group"), else a direct one.
    pub group: bool,
    pub app_path: Option<String>,
    pub focus: Option<String>,
    /// Time of the latest message; becomes `updated_at_ms`.
    pub latest_at_ms: i64,
}

/// An agent process: pid plus start time, which together tell a live agent
/// from a recycled pid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AgentProcessId {
    pub pid: i64,
    pub started_us: i64,
}

/// Where a hook found its agent running; every part is optional.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AgentLocation {
    pub app_path: Option<String>,
    pub app_pid: Option<i64>,
    pub focus: Option<String>,
    pub process: Option<AgentProcessId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSession {
    pub agent: AgentKind,
    pub session_id: String,
    pub state: AgentState,
    pub place: Option<String>,
    pub detail: Option<String>,
    pub app_path: Option<String>,
    pub app_pid: Option<i64>,
    pub focus: Option<String>,
    pub process: Option<AgentProcessId>,
    pub state_seq: i64,
    pub updated_at_ms: i64,
}

/// What a mapped hook does to a session row; the CLI has already mapped the
/// hook's `hook_event_name` (0007's table) to one of these two shapes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentEvent {
    SetState {
        agent: AgentKind,
        session_id: String,
        state: AgentState,
        place: Option<String>,
        detail: Option<String>,
        location: AgentLocation,
    },
    End {
        agent: AgentKind,
        session_id: String,
    },
}

fn read_metadata_i64(conn: &Connection, key: &str) -> CoreResult<Option<i64>> {
    Ok(conn.query_row("SELECT value FROM metadata WHERE key = ?1", [key], |row| row.get(0)).optional()?)
}

/// The counter's current value without bumping it: used for a fresh
/// `Working` row, which is not itself a pet-visible change (0007).
fn current_state_seq(conn: &Connection) -> CoreResult<i64> {
    Ok(read_metadata_i64(conn, STATE_SEQ_KEY)?.unwrap_or(0))
}

/// Bumps (creating at 1 if absent) a monotonic counter in the notes
/// database's `metadata`, so neither deleting rows nor recreating the
/// runtime file ever lowers a watermark a caller has already seen.
fn bump_state_seq(tx: &Transaction<'_>) -> CoreResult<i64> {
    tx.execute(
        "INSERT INTO metadata (key, value) VALUES (?1, 1)
         ON CONFLICT (key) DO UPDATE SET value = value + 1",
        params![STATE_SEQ_KEY],
    )?;
    Ok(read_metadata_i64(tx, STATE_SEQ_KEY)?.expect("just inserted or updated"))
}

const SESSION_COLUMNS: &str = "agent, session_id, state, place, detail, app_path, app_pid, focus,
    agent_pid, agent_started_us, state_seq, updated_at_ms";

fn row_to_session(row: &Row<'_>) -> rusqlite::Result<AgentSession> {
    let invalid = |column, what: &str| {
        rusqlite::Error::FromSqlConversionFailure(column, rusqlite::types::Type::Text, what.to_owned().into())
    };
    let agent: String = row.get(0)?;
    let state: String = row.get(2)?;
    let pid: Option<i64> = row.get(8)?;
    let started_us: Option<i64> = row.get(9)?;
    Ok(AgentSession {
        agent: AgentKind::parse(&agent).ok_or_else(|| invalid(0, "unknown agent"))?,
        session_id: row.get(1)?,
        state: AgentState::parse(&state).ok_or_else(|| invalid(2, "unknown agent state"))?,
        place: row.get(3)?,
        detail: row.get(4)?,
        app_path: row.get(5)?,
        app_pid: row.get(6)?,
        focus: row.get(7)?,
        process: pid.zip(started_us).map(|(pid, started_us)| AgentProcessId { pid, started_us }),
        state_seq: row.get(10)?,
        updated_at_ms: row.get(11)?,
    })
}

fn fetch_row(conn: &Connection, agent: AgentKind, session_id: &str) -> CoreResult<Option<AgentSession>> {
    Ok(conn
        .query_row(
            &format!("SELECT {SESSION_COLUMNS} FROM runtime.agent_sessions WHERE agent = ?1 AND session_id = ?2"),
            params![agent.as_str(), session_id],
            row_to_session,
        )
        .optional()?)
}

/// Rows to prune: idle for 24 h, or whose agent process has gone.
fn dead_rows(
    conn: &Connection,
    now_ms: i64,
    is_alive: &dyn Fn(AgentProcessId) -> bool,
) -> CoreResult<Vec<(String, String)>> {
    let mut statement = conn
        .prepare("SELECT agent, session_id, agent_pid, agent_started_us, updated_at_ms FROM runtime.agent_sessions")?;
    let rows = statement.query_map([], |row| {
        Ok((row.get(0)?, row.get(1)?, row.get::<_, Option<i64>>(2)?, row.get::<_, Option<i64>>(3)?, row.get(4)?))
    })?;
    let mut dead = Vec::new();
    for row in rows {
        let (agent, session_id, pid, started_us, updated_at_ms): (String, String, _, _, i64) = row?;
        let gone = pid.zip(started_us).is_some_and(|(pid, started_us)| !is_alive(AgentProcessId { pid, started_us }));
        if gone || updated_at_ms < now_ms - FRESH_WINDOW_MS {
            dead.push((agent, session_id));
        }
    }
    Ok(dead)
}

fn delete_rows(tx: &Transaction<'_>, rows: &[(String, String)]) -> CoreResult<()> {
    for (agent, session_id) in rows {
        tx.execute(
            "DELETE FROM runtime.agent_sessions WHERE agent = ?1 AND session_id = ?2",
            params![agent, session_id],
        )?;
    }
    Ok(())
}

/// Applies one `SetState` per 0007's write rules; returns whether the row
/// changed in a way the pet/panel should be told about.
#[allow(clippy::too_many_arguments)]
fn set_state(
    tx: &Transaction<'_>,
    agent: AgentKind,
    session_id: &str,
    state: AgentState,
    place: Option<String>,
    detail: Option<String>,
    location: AgentLocation,
    now_ms: i64,
) -> CoreResult<bool> {
    let existing = fetch_row(tx, agent, session_id)?;
    if let Some(existing) = &existing
        && existing.state == state
    {
        // A resumed session can come back under a new process: track it
        // quietly, or the old pid would get the row pruned.
        if let Some(process) = location.process
            && location.process != existing.process
        {
            tx.execute(
                "UPDATE runtime.agent_sessions SET agent_pid = ?3, agent_started_us = ?4,
                    focus = COALESCE(?5, focus), app_path = COALESCE(?6, app_path), app_pid = COALESCE(?7, app_pid)
                 WHERE agent = ?1 AND session_id = ?2",
                params![
                    agent.as_str(),
                    session_id,
                    process.pid,
                    process.started_us,
                    location.focus,
                    location.app_path,
                    location.app_pid
                ],
            )?;
        }
        // A new tool name while already waiting updates what the panel
        // shows, but is not a new attention-worthy transition: no seq bump.
        if state == AgentState::Waiting && existing.detail != detail {
            tx.execute(
                "UPDATE runtime.agent_sessions SET detail = ?3, updated_at_ms = ?4 WHERE agent = ?1 AND session_id = ?2",
                params![agent.as_str(), session_id, detail, now_ms],
            )?;
            return Ok(true);
        }
        return Ok(false);
    }

    // A fresh `Working` row only seeds where the agent runs; it isn't a
    // pet-visible change, so it doesn't bump the counter.
    let pet_visible = existing.is_some() || state == AgentState::Waiting;
    let seq = if pet_visible { bump_state_seq(tx)? } else { current_state_seq(tx)? };
    let process = location.process;
    // Location parts use COALESCE: a write whose lookup found nothing (e.g. a
    // hook run from a background process) keeps what an earlier event found,
    // so a waiting row stays clickable.
    tx.execute(
        &format!(
            "INSERT INTO runtime.agent_sessions ({SESSION_COLUMNS})
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
             ON CONFLICT (agent, session_id) DO UPDATE SET
                state = excluded.state, place = COALESCE(excluded.place, place), detail = excluded.detail,
                app_path = COALESCE(excluded.app_path, app_path), app_pid = COALESCE(excluded.app_pid, app_pid),
                focus = COALESCE(excluded.focus, focus), agent_pid = COALESCE(excluded.agent_pid, agent_pid),
                agent_started_us = COALESCE(excluded.agent_started_us, agent_started_us),
                state_seq = excluded.state_seq, updated_at_ms = excluded.updated_at_ms"
        ),
        params![
            agent.as_str(),
            session_id,
            state.as_str(),
            place,
            detail,
            location.app_path,
            location.app_pid,
            location.focus,
            process.map(|p| p.pid),
            process.map(|p| p.started_us),
            seq,
            now_ms
        ],
    )?;
    Ok(pet_visible)
}

impl Store {
    /// Applies one mapped hook event in a single transaction: prunes dead
    /// and idle rows, then writes the event per 0007's rules. `Ok(true)`
    /// means the app should be told (the CLI posts the change signal on
    /// `true`); this fails only for storage errors.
    pub fn record_agent_event(
        &mut self,
        event: AgentEvent,
        now_ms: i64,
        is_alive: &dyn Fn(AgentProcessId) -> bool,
    ) -> CoreResult<bool> {
        let tx = self.write_tx()?;
        let dead = dead_rows(&tx, now_ms, is_alive)?;
        delete_rows(&tx, &dead)?;
        let changed = match event {
            AgentEvent::SetState { agent, session_id, state, place, detail, location } => {
                set_state(&tx, agent, &session_id, state, place, detail, location, now_ms)?
            }
            AgentEvent::End { agent, session_id } => {
                let count = tx.execute(
                    "DELETE FROM runtime.agent_sessions WHERE agent = ?1 AND session_id = ?2",
                    params![agent.as_str(), session_id],
                )?;
                count > 0
            }
        };
        let changed = changed || !dead.is_empty();
        if changed {
            bump_revision(&tx)?;
        }
        tx.commit()?;
        Ok(changed)
    }

    /// Removes rows whose agent process has gone or that sat idle for 24 h.
    /// Takes the write lock only when there is something to remove; returns
    /// whether anything was. Call before reading sessions or the pet
    /// snapshot, so a terminal closed without a clean exit leaves no ghost.
    pub fn prune_agent_sessions(&mut self, now_ms: i64, is_alive: &dyn Fn(AgentProcessId) -> bool) -> CoreResult<bool> {
        if dead_rows(self.conn(), now_ms, is_alive)?.is_empty() {
            return Ok(false);
        }
        let tx = self.write_tx()?;
        let dead = dead_rows(&tx, now_ms, is_alive)?;
        delete_rows(&tx, &dead)?;
        if !dead.is_empty() {
            bump_revision(&tx)?;
        }
        tx.commit()?;
        Ok(!dead.is_empty())
    }

    /// Replaces `agent`'s rows with the conversations now waiting on the
    /// user (0010); an empty slice clears the source. A new conversation or
    /// a newer message bumps the state seq (the pet waves); a mere change
    /// of display fields does not. Other agents' rows are never touched.
    /// Returns whether anything changed.
    pub fn sync_external_waiting(&mut self, agent: AgentKind, items: &[ExternalWaiting]) -> CoreResult<bool> {
        let tx = self.write_tx()?;
        let mut changed = false;
        let mut keep = Vec::new();
        for item in items {
            // Stay inside the table's CHECKs rather than fail the whole sync.
            if item.id.is_empty() || item.id.chars().count() > 200 {
                continue;
            }
            let place: String = item.who.chars().take(100).collect();
            let detail = item.group.then_some("group");
            let focus = item.focus.as_ref().filter(|f| f.chars().count() <= 200);
            let app_path = item.app_path.as_ref().filter(|p| p.chars().count() <= 4096);
            keep.push(item.id.as_str());
            match fetch_row(&tx, agent, &item.id)? {
                None => {
                    let seq = bump_state_seq(&tx)?;
                    tx.execute(
                        &format!(
                            "INSERT INTO runtime.agent_sessions ({SESSION_COLUMNS})
                             VALUES (?1, ?2, 'waiting', ?3, ?4, ?5, NULL, ?6, NULL, NULL, ?7, ?8)"
                        ),
                        params![agent.as_str(), item.id, place, detail, app_path, focus, seq, item.latest_at_ms],
                    )?;
                    changed = true;
                }
                Some(existing) if item.latest_at_ms > existing.updated_at_ms => {
                    let seq = bump_state_seq(&tx)?;
                    tx.execute(
                        "UPDATE runtime.agent_sessions SET state = 'waiting', place = ?3, detail = ?4, app_path = ?5,
                            focus = ?6, state_seq = ?7, updated_at_ms = ?8 WHERE agent = ?1 AND session_id = ?2",
                        params![agent.as_str(), item.id, place, detail, app_path, focus, seq, item.latest_at_ms],
                    )?;
                    changed = true;
                }
                Some(existing)
                    if existing.place.as_deref() != Some(place.as_str())
                        || existing.detail.as_deref() != detail
                        || existing.app_path.as_ref() != app_path
                        || existing.focus.as_ref() != focus =>
                {
                    tx.execute(
                        "UPDATE runtime.agent_sessions SET place = ?3, detail = ?4, app_path = ?5, focus = ?6
                         WHERE agent = ?1 AND session_id = ?2",
                        params![agent.as_str(), item.id, place, detail, app_path, focus],
                    )?;
                    changed = true;
                }
                Some(_) => {}
            }
        }
        let stale: Vec<String> = {
            let mut statement = tx.prepare("SELECT session_id FROM runtime.agent_sessions WHERE agent = ?1")?;
            let ids = statement.query_map([agent.as_str()], |row| row.get::<_, String>(0))?;
            ids.collect::<Result<Vec<_>, _>>()?
        };
        for id in stale.iter().filter(|id| !keep.contains(&id.as_str())) {
            tx.execute(
                "DELETE FROM runtime.agent_sessions WHERE agent = ?1 AND session_id = ?2",
                params![agent.as_str(), id],
            )?;
            changed = true;
        }
        if changed {
            bump_revision(&tx)?;
        }
        tx.commit()?;
        Ok(changed)
    }

    /// Fresh (≤24h) `waiting` rows, most recent first: `rallo agents` and
    /// the panel's agents section (0007). `working` rows are never shown.
    pub fn agent_sessions(&self, now_ms: i64) -> CoreResult<Vec<AgentSession>> {
        let since = now_ms - FRESH_WINDOW_MS;
        let mut statement = self.conn().prepare(&format!(
            "SELECT {SESSION_COLUMNS} FROM runtime.agent_sessions
             WHERE updated_at_ms >= ?1 AND state = 'waiting'
             ORDER BY updated_at_ms DESC"
        ))?;
        let rows = statement.query_map([since], row_to_session)?.collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Removes sessions matching the given filters (either, both, or
    /// neither); returns the number removed. Not limited to fresh rows:
    /// clearing is an explicit user action, unlike the passive prune.
    pub fn clear_agent_sessions(&mut self, agent: Option<AgentKind>, session_id: Option<&str>) -> CoreResult<u32> {
        let tx = self.write_tx()?;
        let count = match (agent, session_id) {
            (Some(agent), Some(session_id)) => tx.execute(
                "DELETE FROM runtime.agent_sessions WHERE agent = ?1 AND session_id = ?2",
                params![agent.as_str(), session_id],
            )?,
            (Some(agent), None) => {
                tx.execute("DELETE FROM runtime.agent_sessions WHERE agent = ?1", params![agent.as_str()])?
            }
            (None, Some(session_id)) => {
                tx.execute("DELETE FROM runtime.agent_sessions WHERE session_id = ?1", params![session_id])?
            }
            (None, None) => tx.execute("DELETE FROM runtime.agent_sessions", [])?,
        };
        if count > 0 {
            bump_revision(&tx)?;
        }
        tx.commit()?;
        Ok(count as u32)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::database::StoreOptions;

    // `record_agent_event`/`agent_sessions` take `now_ms` explicitly, so the
    // store's own clock never matters here.
    fn open_store() -> (tempfile::TempDir, Store) {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(StoreOptions::new(dir.path())).unwrap();
        (dir, store)
    }

    fn alive(_: AgentProcessId) -> bool {
        true
    }

    fn located(focus: Option<&str>, process: Option<AgentProcessId>) -> AgentLocation {
        AgentLocation {
            app_path: Some("/Applications/Code.app".to_owned()),
            app_pid: Some(123),
            focus: focus.map(str::to_owned),
            process,
        }
    }

    fn set_state_event(agent: AgentKind, session_id: &str, state: AgentState, detail: Option<&str>) -> AgentEvent {
        AgentEvent::SetState {
            agent,
            session_id: session_id.to_owned(),
            state,
            place: Some("tmp/w".to_owned()),
            detail: detail.map(str::to_owned),
            location: located(Some("tty:/dev/ttys001"), None),
        }
    }

    #[test]
    fn working_for_an_unknown_session_inserts_but_is_not_pet_visible() {
        let (_dir, mut store) = open_store();
        let changed = store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Working, None), 1_000_000, &alive)
            .unwrap();
        assert!(!changed);
        let sessions = store.agent_sessions(1_000_000).unwrap();
        assert!(sessions.is_empty(), "working rows are never listed");
    }

    #[test]
    fn waiting_from_scratch_is_pet_visible_and_bumps_seq() {
        let (_dir, mut store) = open_store();
        let changed = store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();
        assert!(changed);
        let sessions = store.agent_sessions(1_000_000).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].state, AgentState::Waiting);
        assert_eq!(sessions[0].detail.as_deref(), Some("Bash"));
        assert!(sessions[0].state_seq > 0);
    }

    #[test]
    fn identical_state_is_a_true_no_op() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();
        let before = store.agent_sessions(1_000_000).unwrap()[0].clone();
        let changed = store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_500,
                &alive,
            )
            .unwrap();
        assert!(!changed);
        let after = store.agent_sessions(1_000_500).unwrap()[0].clone();
        assert_eq!(before.updated_at_ms, after.updated_at_ms, "a true no-op never refreshes updated_at_ms");
        assert_eq!(before.state_seq, after.state_seq);
    }

    #[test]
    fn waiting_with_a_new_detail_updates_without_bumping_seq() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();
        let before = store.agent_sessions(1_000_000).unwrap()[0].clone();
        let changed = store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Read")),
                1_000_500,
                &alive,
            )
            .unwrap();
        assert!(changed);
        let after = store.agent_sessions(1_000_500).unwrap()[0].clone();
        assert_eq!(after.detail.as_deref(), Some("Read"));
        assert_eq!(before.state_seq, after.state_seq, "detail-only updates never bump the seq");
        assert!(after.updated_at_ms > before.updated_at_ms);
    }

    #[test]
    fn a_real_state_change_bumps_seq_and_is_pet_visible() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Working, None), 1_000_000, &alive)
            .unwrap();
        let changed = store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_100,
                &alive,
            )
            .unwrap();
        assert!(changed);
        let sessions = store.agent_sessions(1_000_100).unwrap();
        assert_eq!(sessions.len(), 1);
        assert!(sessions[0].state_seq > 0);
    }

    #[test]
    fn location_survives_a_write_that_found_none() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();

        // Later writes whose ancestry walk found no app pass no app info.
        let without_app = |state, detail: Option<&str>| AgentEvent::SetState {
            agent: AgentKind::Claude,
            session_id: "s1".into(),
            state,
            place: None,
            detail: detail.map(str::to_owned),
            location: AgentLocation::default(),
        };
        store.record_agent_event(without_app(AgentState::Working, None), 1_000_100, &alive).unwrap();
        store.record_agent_event(without_app(AgentState::Waiting, Some("Edit")), 1_000_200, &alive).unwrap();

        let sessions = store.agent_sessions(1_000_200).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].app_path.as_deref(), Some("/Applications/Code.app"), "the earlier lookup is kept");
        assert_eq!(sessions[0].app_pid, Some(123));
        assert_eq!(sessions[0].focus.as_deref(), Some("tty:/dev/ttys001"));
        assert_eq!(sessions[0].place.as_deref(), Some("tmp/w"));
        assert_eq!(sessions[0].detail.as_deref(), Some("Edit"));
    }

    #[test]
    fn end_deletes_and_reports_whether_a_row_existed() {
        let (_dir, mut store) = open_store();
        let missing = store
            .record_agent_event(
                AgentEvent::End { agent: AgentKind::Claude, session_id: "s1".into() },
                1_000_000,
                &alive,
            )
            .unwrap();
        assert!(!missing);

        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();
        let existed = store
            .record_agent_event(
                AgentEvent::End { agent: AgentKind::Claude, session_id: "s1".into() },
                1_000_100,
                &alive,
            )
            .unwrap();
        assert!(existed);
        assert!(store.agent_sessions(1_000_100).unwrap().is_empty());
    }

    #[test]
    fn stale_rows_are_pruned_on_every_write() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "old", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();
        let day_later = 1_000_000 + FRESH_WINDOW_MS + 1;
        // Any write prunes stale rows, even one for an unrelated session.
        store
            .record_agent_event(
                set_state_event(AgentKind::Codex, "new", AgentState::Waiting, Some("Bash")),
                day_later,
                &alive,
            )
            .unwrap();
        let sessions = store.agent_sessions(day_later).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "new");
    }

    #[test]
    fn only_waiting_rows_are_listed_most_recent_first() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "working-old", AgentState::Working, None),
                1_000_000,
                &alive,
            )
            .unwrap();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "working-new", AgentState::Working, None),
                1_000_200,
                &alive,
            )
            .unwrap();
        store
            .record_agent_event(
                set_state_event(AgentKind::Codex, "waiting-old", AgentState::Waiting, Some("Bash")),
                1_000_100,
                &alive,
            )
            .unwrap();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "waiting-new", AgentState::Waiting, None),
                1_000_300,
                &alive,
            )
            .unwrap();
        let sessions = store.agent_sessions(1_000_300).unwrap();
        let ids: Vec<&str> = sessions.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(ids, ["waiting-new", "waiting-old"], "working rows stay hidden");
    }

    #[test]
    fn clear_removes_by_filter_and_reports_the_count() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(
                set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();
        store
            .record_agent_event(
                set_state_event(AgentKind::Codex, "s2", AgentState::Waiting, Some("Bash")),
                1_000_000,
                &alive,
            )
            .unwrap();

        assert_eq!(store.clear_agent_sessions(Some(AgentKind::Claude), None).unwrap(), 1);
        let remaining = store.agent_sessions(1_000_000).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].agent, AgentKind::Codex);

        assert_eq!(store.clear_agent_sessions(None, None).unwrap(), 1);
        assert!(store.agent_sessions(1_000_000).unwrap().is_empty());
    }

    #[test]
    fn rows_whose_agent_process_has_gone_are_pruned() {
        let (_dir, mut store) = open_store();
        let gone = AgentProcessId { pid: 41, started_us: 7 };
        let live = AgentProcessId { pid: 42, started_us: 7 };
        for (id, process) in [("gone", gone), ("live", live)] {
            let event = AgentEvent::SetState {
                agent: AgentKind::Claude,
                session_id: id.into(),
                state: AgentState::Waiting,
                place: None,
                detail: None,
                location: located(None, Some(process)),
            };
            store.record_agent_event(event, 1_000_000, &alive).unwrap();
        }
        let is_alive = |p: AgentProcessId| p != gone;

        let revision = store.change_revision().unwrap();
        assert!(store.prune_agent_sessions(1_000_000, &is_alive).unwrap());
        assert!(store.change_revision().unwrap() > revision, "the panel is told");
        let ids: Vec<String> = store.agent_sessions(1_000_000).unwrap().into_iter().map(|s| s.session_id).collect();
        assert_eq!(ids, ["live"]);
        assert!(!store.prune_agent_sessions(1_000_000, &is_alive).unwrap(), "nothing left to prune");
    }

    #[test]
    fn a_resumed_session_follows_its_new_process() {
        let (_dir, mut store) = open_store();
        let first = AgentProcessId { pid: 41, started_us: 7 };
        let second = AgentProcessId { pid: 99, started_us: 8 };
        let waiting = |process| AgentEvent::SetState {
            agent: AgentKind::Claude,
            session_id: "s1".into(),
            state: AgentState::Waiting,
            place: None,
            detail: None,
            location: located(None, Some(process)),
        };
        store.record_agent_event(waiting(first), 1_000_000, &alive).unwrap();
        store.record_agent_event(waiting(second), 1_000_100, &alive).unwrap();
        assert!(!store.prune_agent_sessions(1_000_100, &|p| p == second).unwrap());
        assert_eq!(store.agent_sessions(1_000_100).unwrap()[0].process, Some(second));
    }

    #[test]
    fn a_runtime_layout_from_another_version_is_recreated_and_seq_stays_monotonic() {
        let dir = tempfile::tempdir().unwrap();
        let seq = {
            let mut store = Store::open(StoreOptions::new(dir.path())).unwrap();
            store
                .record_agent_event(
                    set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, None),
                    1_000_000,
                    &alive,
                )
                .unwrap();
            store.conn().execute_batch("PRAGMA runtime.user_version = 99").unwrap();
            store.agent_sessions(1_000_000).unwrap()[0].state_seq
        };
        let mut store = Store::open(StoreOptions::new(dir.path())).unwrap();
        assert!(store.agent_sessions(1_000_000).unwrap().is_empty(), "disposable rows are dropped");
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "s2", AgentState::Waiting, None), 1_000_100, &alive)
            .unwrap();
        assert!(store.agent_sessions(1_000_100).unwrap()[0].state_seq > seq);
    }

    #[test]
    fn sessions_live_outside_the_notes_database() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(StoreOptions::new(dir.path())).unwrap();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, None), 1_000_000, &alive)
            .unwrap();
        let main_has_table: bool = store
            .conn()
            .query_row("SELECT count(*) > 0 FROM main.sqlite_schema WHERE name = 'agent_sessions'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert!(!main_has_table);
        assert!(
            dir.path()
                .join(crate::storage::database::RUNTIME_DIR)
                .join(crate::storage::database::RUNTIME_FILE)
                .exists()
        );
    }

    #[test]
    fn notify_long_wait_preference_defaults_to_false_and_only_bumps_revision_on_change() {
        let (_dir, mut store) = open_store();
        assert!(!store.agents_notify_long_wait().unwrap());
        assert_eq!(store.change_revision().unwrap(), 0);

        assert!(store.set_agents_notify_long_wait(true).unwrap(), "value changed");
        assert!(store.agents_notify_long_wait().unwrap());
        assert_eq!(store.change_revision().unwrap(), 1);

        assert!(!store.set_agents_notify_long_wait(true).unwrap(), "already true: no-op");
        assert_eq!(store.change_revision().unwrap(), 1);

        assert!(store.set_agents_notify_long_wait(false).unwrap());
        assert!(!store.agents_notify_long_wait().unwrap());
        assert_eq!(store.change_revision().unwrap(), 2);
    }

    fn waiting(id: &str, who: &str, group: bool, at: i64) -> ExternalWaiting {
        ExternalWaiting {
            id: id.to_owned(),
            who: who.to_owned(),
            group,
            app_path: Some("/Applications/ClickUp.app".to_owned()),
            focus: Some(format!("https://app.clickup.com/chat/{id}")),
            latest_at_ms: at,
        }
    }

    #[test]
    fn external_sync_inserts_then_ignores_an_identical_resync() {
        let (_dir, mut store) = open_store();
        let items = [waiting("a", "Ann", false, 1_000_000), waiting("b", "Team", true, 1_000_100)];
        assert!(store.sync_external_waiting(AgentKind::ClickUp, &items).unwrap());
        let rows = store.agent_sessions(1_001_000).unwrap();
        assert_eq!(rows.len(), 2);
        let team = rows.iter().find(|r| r.session_id == "b").unwrap();
        assert_eq!(team.agent, AgentKind::ClickUp);
        assert_eq!(team.place.as_deref(), Some("Team"));
        assert_eq!(team.detail.as_deref(), Some("group"));
        assert_eq!(team.focus.as_deref(), Some("https://app.clickup.com/chat/b"));
        let ann = rows.iter().find(|r| r.session_id == "a").unwrap();
        assert_eq!(ann.detail, None);
        let revision = store.change_revision().unwrap();
        assert!(!store.sync_external_waiting(AgentKind::ClickUp, &items).unwrap());
        assert_eq!(store.change_revision().unwrap(), revision);
    }

    #[test]
    fn external_sync_bumps_the_seq_only_for_a_newer_message() {
        let (_dir, mut store) = open_store();
        store.sync_external_waiting(AgentKind::ClickUp, &[waiting("a", "Ann", false, 1_000_000)]).unwrap();
        let first = store.agent_sessions(1_001_000).unwrap().remove(0);
        // Display-only change: kept timestamp, no seq bump.
        assert!(store.sync_external_waiting(AgentKind::ClickUp, &[waiting("a", "Ann B", false, 1_000_000)]).unwrap());
        let renamed = store.agent_sessions(1_001_000).unwrap().remove(0);
        assert_eq!((renamed.place.as_deref(), renamed.state_seq), (Some("Ann B"), first.state_seq));
        assert_eq!(renamed.updated_at_ms, 1_000_000);
        assert!(store.sync_external_waiting(AgentKind::ClickUp, &[waiting("a", "Ann B", false, 1_000_500)]).unwrap());
        let newer = store.agent_sessions(1_001_000).unwrap().remove(0);
        assert!(newer.state_seq > first.state_seq);
        assert_eq!(newer.updated_at_ms, 1_000_500);
    }

    #[test]
    fn external_sync_deletes_omitted_ids_and_an_empty_slice_clears() {
        let (_dir, mut store) = open_store();
        let both = [waiting("a", "Ann", false, 1_000_000), waiting("b", "Bo", false, 1_000_100)];
        store.sync_external_waiting(AgentKind::ClickUp, &both).unwrap();
        assert!(store.sync_external_waiting(AgentKind::ClickUp, &both[..1]).unwrap());
        let rows = store.agent_sessions(1_001_000).unwrap();
        assert_eq!(rows.iter().map(|r| r.session_id.as_str()).collect::<Vec<_>>(), ["a"]);
        assert!(store.sync_external_waiting(AgentKind::ClickUp, &[]).unwrap());
        assert!(store.agent_sessions(1_001_000).unwrap().is_empty());
        assert!(!store.sync_external_waiting(AgentKind::ClickUp, &[]).unwrap());
    }

    #[test]
    fn external_sync_leaves_other_agents_and_survives_a_dead_process_prune() {
        let (_dir, mut store) = open_store();
        let located = located(None, Some(AgentProcessId { pid: 9, started_us: 1 }));
        let event = AgentEvent::SetState {
            agent: AgentKind::Claude,
            session_id: "c1".to_owned(),
            state: AgentState::Waiting,
            place: None,
            detail: None,
            location: located,
        };
        store.record_agent_event(event, 1_000_000, &alive).unwrap();
        store.sync_external_waiting(AgentKind::ClickUp, &[waiting("a", "Ann", false, 1_000_000)]).unwrap();
        store.sync_external_waiting(AgentKind::ClickUp, &[]).unwrap();
        assert_eq!(store.agent_sessions(1_001_000).unwrap().len(), 1);
        store.sync_external_waiting(AgentKind::ClickUp, &[waiting("a", "Ann", false, 1_000_000)]).unwrap();
        // The Claude row's process is gone; the ClickUp row has none to lose.
        assert!(store.prune_agent_sessions(1_001_000, &|_| false).unwrap());
        let rows = store.agent_sessions(1_001_000).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].agent, AgentKind::ClickUp);
    }

    #[test]
    fn external_sync_truncates_who_and_skips_bad_ids() {
        let (_dir, mut store) = open_store();
        let items = [waiting("a", &"x".repeat(150), false, 1_000_000), waiting("", "No id", false, 1_000_000)];
        store.sync_external_waiting(AgentKind::ClickUp, &items).unwrap();
        let rows = store.agent_sessions(1_001_000).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].place.as_ref().unwrap().chars().count(), 100);
    }
}
