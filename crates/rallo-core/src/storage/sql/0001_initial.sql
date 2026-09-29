-- Rallo schema v1. Timestamps are integer UTC milliseconds since the Unix epoch.
-- Enum-like columns are TEXT with CHECK constraints.

CREATE TABLE metadata (
    key   TEXT PRIMARY KEY,
    value INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

-- Monotonic global revision; bumped only when state actually changes.
INSERT INTO metadata (key, value) VALUES ('change_revision', 0);

CREATE TABLE items (
    id              TEXT PRIMARY KEY,
    short_key       TEXT NOT NULL UNIQUE,
    text            TEXT NOT NULL,
    match_key       TEXT NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('open', 'done')),
    created_at_ms   INTEGER NOT NULL,
    updated_at_ms   INTEGER NOT NULL,
    completed_at_ms INTEGER,
    deleted_at_ms   INTEGER,
    revision        INTEGER NOT NULL CHECK (revision >= 1),
    CHECK ((status = 'done') = (completed_at_ms IS NOT NULL))
) STRICT;

CREATE INDEX items_open_by_created ON items (created_at_ms, id)
    WHERE deleted_at_ms IS NULL AND status = 'open';
CREATE INDEX items_live_by_created ON items (created_at_ms, id)
    WHERE deleted_at_ms IS NULL;
CREATE INDEX items_deleted_by_time ON items (deleted_at_ms, id)
    WHERE deleted_at_ms IS NOT NULL;
CREATE INDEX items_live_match ON items (match_key)
    WHERE deleted_at_ms IS NULL;

CREATE TABLE preferences (
    key           TEXT PRIMARY KEY,
    value         TEXT NOT NULL CHECK (json_valid(value)),
    revision      INTEGER NOT NULL CHECK (revision >= 1),
    updated_at_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
