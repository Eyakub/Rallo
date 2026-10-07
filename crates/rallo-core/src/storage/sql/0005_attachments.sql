-- 0005: images on notes (0018). The files live under
-- <data dir>/attachments/<item id>/<file_name>; this table lists them.
CREATE TABLE attachments (
    id            TEXT PRIMARY KEY,
    item_id       TEXT NOT NULL REFERENCES items (id),
    file_name     TEXT NOT NULL,
    mime_type     TEXT NOT NULL CHECK (mime_type IN ('image/png', 'image/jpeg', 'image/heic', 'image/gif', 'image/webp')),
    byte_size     INTEGER NOT NULL CHECK (byte_size BETWEEN 1 AND 10485760),
    position      INTEGER NOT NULL,
    created_at_ms INTEGER NOT NULL
) STRICT;

CREATE INDEX attachments_item ON attachments (item_id, position);
