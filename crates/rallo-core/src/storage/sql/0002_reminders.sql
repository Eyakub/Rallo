-- Rallo schema v2: one-time reminders and their notification intents.
-- See docs/decisions/0003-core-command-semantics.md for the semantics.

CREATE TABLE reminders (
    id                   TEXT PRIMARY KEY,
    item_id              TEXT NOT NULL UNIQUE REFERENCES items (id),
    deadline_ms          INTEGER NOT NULL,
    time_input           TEXT NOT NULL,       -- verbatim user input: "20m" or RFC 3339
    input_kind           TEXT NOT NULL CHECK (input_kind IN ('relative', 'absolute')),
    input_offset_seconds INTEGER,             -- UTC offset of an absolute input
    enabled              INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    disabled_reason      TEXT CHECK (disabled_reason IN
                           ('acknowledged', 'cancelled', 'item_completed', 'item_deleted', 'imported')),
    acknowledged_at_ms   INTEGER,
    generation           INTEGER NOT NULL CHECK (generation >= 1),
    created_at_ms        INTEGER NOT NULL,
    updated_at_ms        INTEGER NOT NULL,
    CHECK ((enabled = 1) = (disabled_reason IS NULL)),
    CHECK (enabled = 0 OR acknowledged_at_ms IS NULL)
) STRICT;
CREATE INDEX reminders_enabled_deadline ON reminders (deadline_ms) WHERE enabled = 1;

-- 'abandoned' is terminal and lands with M2 (a deadline elapses before an
-- attempt, or an elapsed attempt's outcome is never confirmed); unused in M1.
CREATE TABLE notification_intents (
    id                 INTEGER PRIMARY KEY,
    reminder_id        TEXT NOT NULL REFERENCES reminders (id),
    generation         INTEGER NOT NULL,
    kind               TEXT NOT NULL CHECK (kind IN ('schedule', 'cancel')),
    state              TEXT NOT NULL CHECK (state IN ('pending', 'attempting', 'applied', 'superseded', 'abandoned')),
    created_at_ms      INTEGER NOT NULL,
    attempt_count      INTEGER NOT NULL DEFAULT 0,
    last_attempt_at_ms INTEGER,
    next_attempt_at_ms INTEGER,
    error_code         TEXT,
    resolved_at_ms     INTEGER,
    UNIQUE (reminder_id, generation, kind)
) STRICT;
CREATE INDEX notification_intents_unresolved ON notification_intents (reminder_id)
    WHERE state IN ('pending', 'attempting');

CREATE TABLE notification_observations (
    reminder_id              TEXT PRIMARY KEY REFERENCES reminders (id),
    generation               INTEGER NOT NULL,
    accepted_at_ms           INTEGER,
    pending_observed_at_ms   INTEGER,
    delivered_observed_at_ms INTEGER,
    observed_at_ms           INTEGER NOT NULL
) STRICT;

CREATE TABLE request_receipts (
    request_id    TEXT PRIMARY KEY,
    fingerprint   TEXT NOT NULL,     -- canonical JSON of the command's original inputs
    command_kind  TEXT NOT NULL,
    item_id       TEXT,
    result        TEXT NOT NULL CHECK (json_valid(result)),
    created_at_ms INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

-- Exact-match search/delete-by-text needs match_key equality across all
-- items (including deleted, for --include-deleted search); items_live_match
-- (0001) only covers the nondeleted subset used by literal substring search.
CREATE INDEX items_match_key ON items (match_key);
