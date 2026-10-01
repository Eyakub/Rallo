//! Agent attention (0007): sessions Claude Code/Codex hooks report through
//! `rallo agent-event`, and the read paths the pet reducer (`pet::mod`) and
//! `rallo agents` build on.
//!
//! `record_agent_event` never stores prompt or model text (`detail` is a
//! fixed-template tool name at most); the caller (the CLI) has already mapped
//! a raw hook payload to one of the two `AgentEvent` variants below per
//! 0007's event table.

use rusqlite::{Connection, OptionalExtension, Row, Transaction, params};

use crate::shared::errors::CoreResult;
use crate::storage::database::{Store, bump_revision};

const STATE_SEQ_KEY: &str = "agents.state_seq";

/// Rows not updated within this window are pruned on every write and
/// excluded from every read (`agent_sessions`, `pet_snapshot`).
pub(crate) const FRESH_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentKind {
    Claude,
    Codex,
}

impl AgentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    Working,
    Waiting,
    /// No longer written: a finished turn removes the row (0007, amended
    /// 2026-10-01). Still parsed for rows written before that, which the
    /// 24 h prune removes.
    Done,
}

impl AgentState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Waiting => "waiting",
            Self::Done => "done",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "working" => Some(Self::Working),
            "waiting" => Some(Self::Waiting),
            "done" => Some(Self::Done),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentSession {
    pub agent: AgentKind,
    pub session_id: String,
    pub state: AgentState,
    pub cwd: Option<String>,
    pub detail: Option<String>,
    pub app_path: Option<String>,
    pub app_pid: Option<i64>,
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
        cwd: Option<String>,
        detail: Option<String>,
        app_path: Option<String>,
        app_pid: Option<i64>,
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

/// Bumps (creating at 1 if absent) the same kind of monotonic counter
/// `pet::increment_completion_seq`/`increment_save_seq` use, so deleting rows
/// later never lowers a watermark a caller has already seen.
fn bump_state_seq(tx: &Transaction<'_>) -> CoreResult<i64> {
    tx.execute(
        "INSERT INTO metadata (key, value) VALUES (?1, 1)
         ON CONFLICT (key) DO UPDATE SET value = value + 1",
        params![STATE_SEQ_KEY],
    )?;
    Ok(read_metadata_i64(tx, STATE_SEQ_KEY)?.expect("just inserted or updated"))
}

fn row_to_session(row: &Row<'_>) -> rusqlite::Result<AgentSession> {
    let agent: String = row.get(0)?;
    let state: String = row.get(2)?;
    Ok(AgentSession {
        agent: AgentKind::parse(&agent).ok_or_else(|| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, "unknown agent".into())
        })?,
        session_id: row.get(1)?,
        state: AgentState::parse(&state).ok_or_else(|| {
            rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, "unknown agent state".into())
        })?,
        cwd: row.get(3)?,
        detail: row.get(4)?,
        app_path: row.get(5)?,
        app_pid: row.get(6)?,
        state_seq: row.get(7)?,
        updated_at_ms: row.get(8)?,
    })
}

const SESSION_COLUMNS: &str = "agent, session_id, state, cwd, detail, app_path, app_pid, state_seq, updated_at_ms";

fn fetch_row(conn: &Connection, agent: AgentKind, session_id: &str) -> CoreResult<Option<AgentSession>> {
    Ok(conn
        .query_row(
            &format!("SELECT {SESSION_COLUMNS} FROM agent_sessions WHERE agent = ?1 AND session_id = ?2"),
            params![agent.as_str(), session_id],
            row_to_session,
        )
        .optional()?)
}

fn prune_stale(tx: &Transaction<'_>, now_ms: i64) -> CoreResult<()> {
    tx.execute("DELETE FROM agent_sessions WHERE updated_at_ms < ?1", params![now_ms - FRESH_WINDOW_MS])?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn insert_row(
    tx: &Transaction<'_>,
    agent: AgentKind,
    session_id: &str,
    state: AgentState,
    cwd: Option<&str>,
    detail: Option<&str>,
    app_path: Option<&str>,
    app_pid: Option<i64>,
    state_seq: i64,
    now_ms: i64,
) -> CoreResult<()> {
    tx.execute(
        &format!("INSERT INTO agent_sessions ({SESSION_COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"),
        params![agent.as_str(), session_id, state.as_str(), cwd, detail, app_path, app_pid, state_seq, now_ms],
    )?;
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
    cwd: Option<String>,
    detail: Option<String>,
    app_path: Option<String>,
    app_pid: Option<i64>,
    now_ms: i64,
) -> CoreResult<bool> {
    match fetch_row(tx, agent, session_id)? {
        None => {
            if state == AgentState::Working {
                // Not a pet-visible change: seeds app info for a later
                // waiting/done event without bumping the counter.
                let seq = current_state_seq(tx)?;
                insert_row(
                    tx,
                    agent,
                    session_id,
                    state,
                    cwd.as_deref(),
                    detail.as_deref(),
                    app_path.as_deref(),
                    app_pid,
                    seq,
                    now_ms,
                )?;
                Ok(false)
            } else {
                let seq = bump_state_seq(tx)?;
                insert_row(
                    tx,
                    agent,
                    session_id,
                    state,
                    cwd.as_deref(),
                    detail.as_deref(),
                    app_path.as_deref(),
                    app_pid,
                    seq,
                    now_ms,
                )?;
                Ok(true)
            }
        }
        Some(existing) => {
            if existing.state == state {
                // A rising `Waiting` event with a different tool name (e.g.
                // the agent finished one permission request and immediately
                // hit another) still updates what the panel shows, but is
                // not a new attention-worthy transition: no seq bump.
                if state == AgentState::Waiting && existing.detail != detail {
                    tx.execute(
                        "UPDATE agent_sessions SET detail = ?3, updated_at_ms = ?4 WHERE agent = ?1 AND session_id = ?2",
                        params![agent.as_str(), session_id, detail, now_ms],
                    )?;
                    Ok(true)
                } else {
                    Ok(false)
                }
            } else {
                let seq = bump_state_seq(tx)?;
                // `app_path`/`app_pid` use COALESCE: a write whose ancestry
                // walk found no app (e.g. a hook run from a background
                // process) keeps whatever terminal an earlier event found, so
                // a waiting row stays clickable.
                tx.execute(
                    "UPDATE agent_sessions SET state = ?3, cwd = ?4, detail = ?5,
                        app_path = COALESCE(?6, app_path), app_pid = COALESCE(?7, app_pid),
                        state_seq = ?8, updated_at_ms = ?9
                     WHERE agent = ?1 AND session_id = ?2",
                    params![agent.as_str(), session_id, state.as_str(), cwd, detail, app_path, app_pid, seq, now_ms],
                )?;
                Ok(true)
            }
        }
    }
}

impl Store {
    /// Applies one mapped hook event in a single transaction: prunes rows
    /// idle for 24h, then writes the event per 0007's rules. `Ok(true)` means
    /// the app should be told (the CLI posts the change signal on `true`);
    /// this never fails for anything the CLI itself already validated, only
    /// for storage errors.
    pub fn record_agent_event(&mut self, event: AgentEvent, now_ms: i64) -> CoreResult<bool> {
        let tx = self.write_tx()?;
        prune_stale(&tx, now_ms)?;
        let changed = match event {
            AgentEvent::SetState { agent, session_id, state, cwd, detail, app_path, app_pid } => {
                set_state(&tx, agent, &session_id, state, cwd, detail, app_path, app_pid, now_ms)?
            }
            AgentEvent::End { agent, session_id } => {
                let count = tx.execute(
                    "DELETE FROM agent_sessions WHERE agent = ?1 AND session_id = ?2",
                    params![agent.as_str(), session_id],
                )?;
                count > 0
            }
        };
        if changed {
            bump_revision(&tx)?;
        }
        tx.commit()?;
        Ok(changed)
    }

    /// Fresh (≤24h) `waiting` rows, most recent first: `rallo agents` and
    /// the panel's "Agents" section (0007). Only agents waiting on the user
    /// are shown; `working` rows and legacy `done` rows never are.
    pub fn agent_sessions(&self, now_ms: i64) -> CoreResult<Vec<AgentSession>> {
        let since = now_ms - FRESH_WINDOW_MS;
        let mut statement = self.conn().prepare(&format!(
            "SELECT {SESSION_COLUMNS} FROM agent_sessions
             WHERE updated_at_ms >= ?1 AND state = 'waiting'
             ORDER BY updated_at_ms DESC"
        ))?;
        let rows = statement.query_map([since], row_to_session)?.collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Removes sessions matching the given filters (either, both, or
    /// neither); returns the number removed. Not limited to fresh rows:
    /// clearing is an explicit user action, unlike the passive 24h prune.
    pub fn clear_agent_sessions(&mut self, agent: Option<AgentKind>, session_id: Option<&str>) -> CoreResult<u32> {
        let tx = self.write_tx()?;
        let count = match (agent, session_id) {
            (Some(agent), Some(session_id)) => tx.execute(
                "DELETE FROM agent_sessions WHERE agent = ?1 AND session_id = ?2",
                params![agent.as_str(), session_id],
            )?,
            (Some(agent), None) => {
                tx.execute("DELETE FROM agent_sessions WHERE agent = ?1", params![agent.as_str()])?
            }
            (None, Some(session_id)) => {
                tx.execute("DELETE FROM agent_sessions WHERE session_id = ?1", params![session_id])?
            }
            (None, None) => tx.execute("DELETE FROM agent_sessions", [])?,
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

    fn set_state_event(agent: AgentKind, session_id: &str, state: AgentState, detail: Option<&str>) -> AgentEvent {
        AgentEvent::SetState {
            agent,
            session_id: session_id.to_owned(),
            state,
            cwd: Some("/tmp/w".to_owned()),
            detail: detail.map(str::to_owned),
            app_path: Some("/Applications/Code.app".to_owned()),
            app_pid: Some(123),
        }
    }

    #[test]
    fn working_for_an_unknown_session_inserts_but_is_not_pet_visible() {
        let (_dir, mut store) = open_store();
        let changed = store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Working, None), 1_000_000)
            .unwrap();
        assert!(!changed);
        let sessions = store.agent_sessions(1_000_000).unwrap();
        assert!(sessions.is_empty(), "working rows are never listed");
    }

    #[test]
    fn waiting_from_scratch_is_pet_visible_and_bumps_seq() {
        let (_dir, mut store) = open_store();
        let changed = store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_000)
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
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_000)
            .unwrap();
        let before = store.agent_sessions(1_000_000).unwrap()[0].clone();
        let changed = store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_500)
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
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_000)
            .unwrap();
        let before = store.agent_sessions(1_000_000).unwrap()[0].clone();
        let changed = store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Read")), 1_000_500)
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
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Working, None), 1_000_000)
            .unwrap();
        let changed = store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_100)
            .unwrap();
        assert!(changed);
        let sessions = store.agent_sessions(1_000_100).unwrap();
        assert_eq!(sessions.len(), 1);
        assert!(sessions[0].state_seq > 0);
    }

    #[test]
    fn app_path_and_pid_survive_a_write_that_found_no_app() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_000)
            .unwrap();

        // Later writes whose ancestry walk found no app pass no app info.
        let without_app = |state, detail: Option<&str>| AgentEvent::SetState {
            agent: AgentKind::Claude,
            session_id: "s1".into(),
            state,
            cwd: Some("/tmp/w".into()),
            detail: detail.map(str::to_owned),
            app_path: None,
            app_pid: None,
        };
        store.record_agent_event(without_app(AgentState::Working, None), 1_000_100).unwrap();
        store.record_agent_event(without_app(AgentState::Waiting, Some("Edit")), 1_000_200).unwrap();

        let sessions = store.agent_sessions(1_000_200).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].app_path.as_deref(), Some("/Applications/Code.app"), "the earlier lookup is kept");
        assert_eq!(sessions[0].app_pid, Some(123));
        assert_eq!(sessions[0].detail.as_deref(), Some("Edit"));
    }

    #[test]
    fn end_deletes_and_reports_whether_a_row_existed() {
        let (_dir, mut store) = open_store();
        let missing = store
            .record_agent_event(AgentEvent::End { agent: AgentKind::Claude, session_id: "s1".into() }, 1_000_000)
            .unwrap();
        assert!(!missing);

        store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_000)
            .unwrap();
        let existed = store
            .record_agent_event(AgentEvent::End { agent: AgentKind::Claude, session_id: "s1".into() }, 1_000_100)
            .unwrap();
        assert!(existed);
        assert!(store.agent_sessions(1_000_100).unwrap().is_empty());
    }

    #[test]
    fn stale_rows_are_pruned_on_every_write() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "old", AgentState::Waiting, Some("Bash")), 1_000_000)
            .unwrap();
        let day_later = 1_000_000 + FRESH_WINDOW_MS + 1;
        // Any write prunes stale rows, even one for an unrelated session.
        store
            .record_agent_event(set_state_event(AgentKind::Codex, "new", AgentState::Waiting, Some("Bash")), day_later)
            .unwrap();
        let sessions = store.agent_sessions(day_later).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "new");
    }

    #[test]
    fn only_waiting_rows_are_listed_most_recent_first() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "done-old", AgentState::Done, None), 1_000_000)
            .unwrap();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "done-new", AgentState::Done, None), 1_000_200)
            .unwrap();
        store
            .record_agent_event(
                set_state_event(AgentKind::Codex, "waiting-old", AgentState::Waiting, Some("Bash")),
                1_000_100,
            )
            .unwrap();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "waiting-new", AgentState::Waiting, None), 1_000_300)
            .unwrap();
        let sessions = store.agent_sessions(1_000_300).unwrap();
        let ids: Vec<&str> = sessions.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(ids, ["waiting-new", "waiting-old"], "done rows (no longer written) stay hidden");
    }

    #[test]
    fn clear_removes_by_filter_and_reports_the_count() {
        let (_dir, mut store) = open_store();
        store
            .record_agent_event(set_state_event(AgentKind::Claude, "s1", AgentState::Waiting, Some("Bash")), 1_000_000)
            .unwrap();
        store
            .record_agent_event(set_state_event(AgentKind::Codex, "s2", AgentState::Waiting, Some("Bash")), 1_000_000)
            .unwrap();

        assert_eq!(store.clear_agent_sessions(Some(AgentKind::Claude), None).unwrap(), 1);
        let remaining = store.agent_sessions(1_000_000).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].agent, AgentKind::Codex);

        assert_eq!(store.clear_agent_sessions(None, None).unwrap(), 1);
        assert!(store.agent_sessions(1_000_000).unwrap().is_empty());
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
}
