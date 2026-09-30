-- Rallo schema v3: agent attention (Claude Code / Codex hook events).
-- See docs/decisions/0007-agent-attention.md for the semantics.

CREATE TABLE agent_sessions (
  agent         TEXT NOT NULL CHECK (agent IN ('claude', 'codex')),
  session_id    TEXT NOT NULL CHECK (length(session_id) BETWEEN 1 AND 200),
  state         TEXT NOT NULL CHECK (state IN ('working', 'waiting', 'done')),
  cwd           TEXT CHECK (cwd IS NULL OR length(cwd) <= 4096),
  detail        TEXT CHECK (detail IS NULL OR length(detail) <= 120),
  app_path      TEXT CHECK (app_path IS NULL OR length(app_path) <= 4096),
  app_pid       INTEGER,
  state_seq     INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (agent, session_id)
) STRICT, WITHOUT ROWID;
