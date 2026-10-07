# Backup and restore

Rallo keeps one SQLite database at the data directory `rallo status` reports
(`~/Library/Application Support/Razlio/Rallo/rallo.sqlite3` by default). This
page covers every kind of copy Rallo makes or can make of it, and the exact
steps to restore from one.

## Kinds of copies

| Copy | When it happens | Where |
|---|---|---|
| Pre-migration snapshot | Automatic, once, the first time an older on-disk schema is opened by a newer build | `<data dir>/backups/pre-migration-v<found>-<now_ms>.sqlite3` |
| Pre-import snapshot | Automatic, before `rallo import` (without `--dry-run`) writes anything | `<data dir>/backups/pre-import-<now_ms>.sqlite3` |
| Manual backup | `rallo backup` | `<data dir>/backups/manual-<now_ms>.sqlite3` by default, or `--output PATH` |
| Manual backup, images | `rallo backup` also copies `attachments/` | `<output>.attachments/` beside the backup |
| Export | `rallo export --output PATH [--format json\|csv]` | wherever `--output` points |
| Export with images | `rallo export --format zip` | a zip with `rallo-export.json` (version 2) and `images/` |

The two automatic snapshots and `rallo backup` are all full, consistent
copies of the SQLite database file (via SQLite's online backup API, which
includes any content only present in the write-ahead log), mode `0600`.
`rallo backup` is the only one you invoke directly to get an on-demand,
restorable copy of everything, and it works whether or not the app is
currently running.

`rallo export` is a different kind of document: a versioned, human-readable
snapshot of items and reminder *intent* (JSON keeps everything except images,
which a zip export keeps too; CSV excludes deleted items and most reminder detail). It never carries native
scheduling/delivery evidence, and importing it always leaves reminders
disabled until you explicitly reschedule them (see `docs/cli-contract.md`).
Prefer `rallo backup` when you want to restore exactly what you had; prefer
`rallo export` when you want a portable, readable copy or to move notes into
a different data directory.

`rallo doctor` reports the count and newest file under `<data dir>/backups/`
so you can see at a glance whether recent snapshots exist.

## Restoring from a `rallo backup` (or automatic) snapshot

A snapshot is a complete, standalone copy of `rallo.sqlite3` — restoring
means putting it back in place of the live database.

1. Quit Rallo from its menu bar item (not just close the notes panel).
2. Run `rallo status` and note the `data` directory it prints.
3. Move the live files aside (do not delete them yet):
   ```sh
   cd "<data dir from step 2>"
   mkdir -p quarantine
   mv rallo.sqlite3 rallo.sqlite3-wal rallo.sqlite3-shm quarantine/ 2>/dev/null
   ```
   (`-wal`/`-shm` may not exist; that is fine.)
4. Copy the chosen snapshot into place and fix its permissions:
   ```sh
   cp <data dir>/backups/manual-<timestamp>.sqlite3 rallo.sqlite3
   chmod 600 rallo.sqlite3
   ```
5. If the backup has a `manual-<timestamp>.sqlite3.attachments` folder beside
   it, put it back too:
   ```sh
   mv attachments quarantine/ 2>/dev/null; cp -R <backup>.attachments attachments; chmod 700 attachments
   ```
6. Reopen Rallo (`rallo show`, or launch it normally).
7. Run `rallo doctor` to confirm the restored store is healthy (schema
   version, integrity check, permissions) before relying on it. Once you are
   satisfied, delete the `quarantine/` directory.

Pre-migration and pre-import snapshots hold only the database; image files
are never changed after they are written. After restoring one, images added
since are files no note owns, and the app removes them an hour later. Images a
restored note refers to but whose files were removed since show as missing in
`rallo doctor`.

Restoring does not bring back notifications macOS has already delivered —
those are gone once dismissed or acted on, independent of the database. The
app re-schedules any still-future reminders it finds enabled when it next
launches; past-due reminders follow the normal overdue handling
(`docs/decisions/0005-notification-protocol.md`), not an automatic replay.

## Restoring from an export

A `.zip` is imported the same way (`rallo import --file rallo-export.zip`),
images included. An export is not a drop-in replacement for the database file; it is applied
through `rallo import`, which validates the whole document before writing
anything and never overwrites conflicting existing records.

1. Preview the import without changing anything:
   ```sh
   rallo import --file rallo-export.json --dry-run
   ```
   Review the reported new/identical/conflicting counts. Any conflict aborts
   the whole import (dry run or not) with nothing written; resolve it (e.g.
   import into a fresh data directory) before proceeding.
2. Apply it:
   ```sh
   rallo import --file rallo-export.json
   ```
   This takes its own automatic pre-import snapshot first (see the table
   above), then applies the whole document in one transaction.
3. Imported reminders are always created disabled. Explicitly reschedule any
   you want active again (`rallo reschedule ID --in ...`) — this is
   deliberate, so a large import never bursts a pile of stale alerts.

As with a database-file restore, an import cannot resurrect notifications
macOS already delivered before the export was taken; only reminders you
reschedule after import produce new native notifications.

## See also

- `docs/cli-contract.md` — `doctor`, `backup`, `export`, `import` command
  reference.
- `docs/decisions/0004-export-import-formats.md` — export/import format and
  conflict rules.
- `docs/decisions/0005-notification-protocol.md` — why a restored or
  re-imported reminder does not replay a notification macOS already showed.
