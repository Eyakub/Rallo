-- 0006: folders (0019). Notes with no folder are in the built-in "Notes".
CREATE TABLE folders (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    name_key      TEXT NOT NULL UNIQUE,  -- trim + NFC + case fold (0003 §6)
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    revision      INTEGER NOT NULL CHECK (revision >= 1)
) STRICT;

ALTER TABLE items ADD COLUMN folder_id TEXT REFERENCES folders (id);

CREATE INDEX items_open_by_folder ON items (folder_id, created_at_ms, id)
    WHERE deleted_at_ms IS NULL AND status = 'open';
