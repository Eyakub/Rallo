-- Rallo schema v4: agent sessions leave the notes database (0009). They are
-- runtime state kept in <data dir>/runtime/agents.sqlite3, which is never
-- backed up, exported, or migrated. `agents.state_seq` stays in `metadata`
-- so the pet's watermarks keep rising across runtime-file resets.

DROP TABLE IF EXISTS agent_sessions;
