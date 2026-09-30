# 0004 — Export/import formats

- **Status:** Accepted for M4 implementation.
- **Date:** 2026-09-30
- **Implements:** section 10 ("Privacy and data lifecycle") and the
  `rallo export`/`rallo import` entries of section 5 of
  `rallo-macos-build-plan.md`. Builds on
  `docs/decisions/0003-core-command-semantics.md` (schema v2, `reminders`
  states, `disabled_reason = 'imported'`).

Two formats, for two different jobs: a lossless JSON backup for disaster
recovery/device transfer, and a spreadsheet-friendly CSV for someone who
wants to open their notes in Excel/Numbers/Sheets. CSV is explicitly a lossy
export; JSON is not.

## 1. JSON backup (`ExportFormat::Json`)

```json
{
  "format": "rallo.export",
  "version": 1,
  "exported_at": "2026-09-30T08:00:00Z",
  "core_version": "0.1.0",
  "schema_version": 2,
  "items": [
    {
      "id": "6a54240d-942e-4a71-b25a-96586db2b104",
      "text": "Review deployment",
      "status": "open",
      "created_at_ms": 1234567890000,
      "updated_at_ms": 1234567890000,
      "completed_at_ms": null,
      "deleted_at_ms": null,
      "reminder": null
    }
  ]
}
```

`version` is the shape of this document, independent of `schema_version`
(the *database* schema at export time, informational only — import never
gates on it, only on `version`). A `reminder`, when present, is
`{"id","deadline_ms","time_input","input_kind","input_offset_seconds",
"state","acknowledged_at_ms","created_at_ms","updated_at_ms"}`.

Includes done and deleted items. Items are ordered `created_at_ms` ascending,
then `id`. **Excludes** `notification_intents`, `notification_observations`,
and `request_receipts`: native acceptance/delivery evidence is not
authoritative state (build plan §10), and a receipt is meaningless once
replayed into a different database. `reminder.state` is the *derived* state
(0003 §2) for a human/debugging read of the document; import does not trust
it — see §4.

Read with one `unchecked_transaction` (`Connection::unchecked_transaction`,
`TransactionBehavior::Deferred`) over the whole snapshot: in WAL mode the
first statement fixes the read snapshot for the rest of the transaction, so a
concurrent writer's commits are invisible to an export already in progress.
No `BEGIN IMMEDIATE` (no write lock) is needed for a read.

## 2. CSV (`ExportFormat::Csv`)

RFC 4180, UTF-8 with a leading BOM (`EF BB BF`, for Excel's encoding
detection) and CRLF record terminators. Header:

```
id,text,status,created_at,completed_at,reminder_at,reminder_state
```

Times are RFC 3339 UTC; empty when absent. **Excludes deleted items** —
there is no CSV column for a deleted timestamp, and silently resurrecting a
deleted note on import would be worse than just not exporting it. Also
excludes reminder settings beyond a resolved deadline and its derived state:
no `time_input`/`input_kind`/`input_offset_seconds`/`generation` column.

**Formula-injection guard:** a `text` cell starting with `=`, `+`, `-`, `@`,
a tab, or a carriage return is prefixed with `'` on export (spreadsheet
applications otherwise treat that as a formula/command), and import removes
exactly that `'`. So that the guard is always distinguishable from a note's
own apostrophe, a note that already starts with apostrophes followed by one
of those characters is guarded too (`'=x` exports as `''=x`). An ordinary
leading apostrophe (`'tis the season`) is never touched. The mapping is
lossless for every text Rallo exports; a hand-made CSV whose cell starts
with `'` + a trigger character loses that first `'` on import, which is the
spreadsheet convention anyway.

## 3. Writing files (`Store::export_to_file`)

Atomic: a temp file in the destination's own directory, `fsync`ed, then
renamed over the destination; mode `0600`. Refuses to overwrite an existing
file unless `overwrite: true` (CLI `--force`; the GUI save panel passes
`true` only after its own confirmation dialog). The existence check runs
before the (potentially slow) database snapshot, so a missing `--force`
fails fast. `--output -` bypasses the file path entirely and writes
`export_bytes` straight to stdout (`Store::export_bytes`, no file, no
`overwrite` question).

As with any check-then-rename sequence over a filesystem, another process
could recreate the destination between the existence check and the final
rename. This tool has exactly one local user and does not reach for a
nonstandard exclusive-rename syscall to close that window.

## 4. Import (`Store::preview_import` / `Store::apply_import`)

**Format detection** is content-based, not by file extension: a JSON object
tagged `"format": "rallo.export"` is the backup; anything else (including
syntactically invalid JSON) is read as CSV, where it fails CSV's own
validation if it is not that either.

**Validation** happens before any write, over the *entire* document:

- JSON: `version` must be `<=` the version this build supports (else
  `CoreError::IncompatibleSchema`, exit 7 — the same shape as a database
  opened with a newer schema than the binary understands). Every item's `id`
  must be a UUID; `status` one of `open`/`done`; `text` via
  `shared::text::validate_note_text` (non-empty, `<= 64` KiB); `completed_at_ms`
  set if and only if `status == "done"` (the same invariant as the `items`
  table's own CHECK constraint); a `reminder`'s `input_kind` one of
  `relative`/`absolute`, `time_input` non-empty, `state` one of the five
  derived reminder states, `acknowledged_at_ms` set if and only if
  `state == "acknowledged"`. No duplicate `id` within the document.
- CSV: header required, columns matched case-insensitively; `text` is
  required (its absence is rejected before any row is read); `id`, `status`
  (default `open`), `created_at` (default "now" *at insert time* — not
  compared for dedupe when omitted, see below), `completed_at`,
  `reminder_at`, `reminder_state` are optional. Unknown columns are ignored
  with a warning, not rejected. `completed_at` presence must match
  `status == "done"`, mirroring the JSON rule. `reminder_state` requires
  `reminder_at` to also be present (there is nothing to hold a state for
  otherwise).
- Both: a 64 MiB file-size cap, checked before any parsing. Every rejection
  names the record index (JSON) or line number (CSV) and the offending
  field, and never echoes note text (`INVALID_IMPORT`, exit 2).

**Classification** (`new` / `identical` / `conflict`), per record:

- **With an id** (always for JSON; optional for CSV): looked up directly.
  Missing → `new`. Found → compare `text`, `status`, `completed_at_ms`,
  `deleted_at_ms` (always), `created_at_ms`/`updated_at_ms` (only when the
  record actually carries a value — CSV may omit them), and the reminder's
  *resolved deadline* only. All equal → `identical` (a no-op); any
  difference → `conflict`.

  The reminder comparison is deliberately narrower than "every exported
  field": import always normalizes an inserted reminder to
  `disabled_reason = 'imported'`, generation 1, no acknowledgement (§5).
  Comparing that bookkeeping against a record's original `state`/
  `acknowledged_at_ms` would make re-importing the *same file a second time*
  look like a conflict on every reminder it carries, defeating the entire
  point of the `identical` no-op. The deadline is what survives import
  unchanged, so it is what defines "the same reminder" for this purpose.

- **Without an id** (CSV only): there is no identity assertion to conflict
  with. `identical` means an existing, nondeleted item with byte-equal
  (unnormalized — not `match_key`-folded) `text` *and* an equal `created_at`,
  when the row gives one. A row with neither an id nor a `created_at` is
  always `new`, even if byte-identical to a row already imported: there is
  nothing to key a dedupe on, and silently deduping on `text` alone would
  merge two unrelated notes that happen to say the same thing.

**Any conflict aborts the whole import, dry run or not**, with nothing
written: `CoreError::Conflict` under a new `IMPORT_CONFLICT` code (exit 4),
carrying a bounded list (`MAX_REPORTED_CONFLICTS = 20`; `total` is exact even
when the list is truncated) of `{id, line, index, reason}` — never note
text — under `ConflictDetail::ImportConflicts`. `rallo import --dry-run`
against a conflicting document therefore reports the same exit code and
nothing-changed guarantee a real import would; a dry run is not "always
exit 0", it is "always writes nothing".

**Applying** (`apply_import` only): classification runs twice — once against
the connection's plain (non-transactional) committed state, so a document
that cannot apply never causes a backup snapshot to be taken; and again
inside a `BEGIN IMMEDIATE` transaction, immediately before writing, to catch
a conflict introduced by a concurrent writer between the two checks. The
SQLite online backup (`storage::backup::snapshot`, the same helper
`storage::migrations` uses) is deliberately taken on the plain connection,
*not* inside the `BEGIN IMMEDIATE` transaction: empirically, running the
backup API against a connection that already has its own write transaction
open never completes. If the second (in-transaction) classification finds a
conflict that the first missed, the just-taken backup file is removed before
returning the error, keeping "any conflict... nothing written" true of the
filesystem as well as the database.

Imported items always get `revision = 1` and `short_key`/`match_key` derived
fresh, regardless of the original item's revision — revision is not part of
the exported shape, so this is not a loss. Imported reminders are **always**
`disabled_reason = 'imported'`, `generation = 1`, with **no**
`notification_intents` row, regardless of what the source document's
`state`/CSV `reminder_state` said: an import must never schedule a burst of
stale native alerts. The user re-arms a reminder explicitly (`reschedule`)
once they are ready for it to fire again. `change_revision` bumps once, only
if at least one record was actually inserted.

## 5. Result shape

```json
{ "format": "json" | "csv", "total_records": 3, "new": 2, "identical": 1,
  "conflicts": [], "warnings": [], "applied": true,
  "backup_path": "/.../backups/pre-import-1730000000000.sqlite3" }
```

`conflicts` is always empty here: a real conflict is reported as the
`IMPORT_CONFLICT` error above, not folded into a success value with a
partial result. `applied` distinguishes `preview_import` (`false`,
`backup_path: null`) from `apply_import` (`true`, `backup_path: Some(..)`
even when `new == 0`, since a backup is unconditional whenever an apply
attempt actually reaches the write transaction).

## 6. Error codes and exit codes

| Code | Meaning | Exit |
|---|---|---|
| `INVALID_IMPORT` | Document fails validation before any write | 2 |
| `IMPORT_CONFLICT` | A record's id matches an existing item with different content | 4 |
| `FILE_EXISTS` | `export_to_file` without `overwrite`/`--force` | 4 |
| `INCOMPATIBLE_SCHEMA` | The document's `version` is newer than this build supports | 7 |

`FILE_EXISTS` is a conflict (4), not a usage error (2): the arguments are
valid, and the failure is a naming collision with existing on-disk state —
the same category as `REVISION_CONFLICT`/`AMBIGUOUS_ID`, and resolved the
same way (`overwrite: true`/`--force`, the same shape as `--if-revision`
resolving a stale revision). `INVALID_IMPORT` stays exit 2 because, like
every other input-validation failure in this CLI (0003 §9), nothing is
committed and the caller's document, not the store, is at fault.

## 7. Core API (for the later FFI)

```rust
pub enum ExportFormat { Json, Csv }
pub struct ExportSummary { pub items: u64, pub path: PathBuf }
pub struct ImportReport {
    pub format: ExportFormat,
    pub total_records: u64,
    pub new: u64,
    pub identical: u64,
    pub conflicts: Vec<ImportConflictRecord>,
    pub warnings: Vec<String>,
    pub applied: bool,
    pub backup_path: Option<PathBuf>,
}
pub struct ImportConflictRecord { pub id: Option<Uuid>, pub line: Option<u64>, pub index: Option<u64>, pub reason: String }

impl Store {
    pub fn export_bytes(&self, format: ExportFormat) -> CoreResult<Vec<u8>>;
    pub fn export_to_file(&self, path: &Path, format: ExportFormat, overwrite: bool) -> CoreResult<ExportSummary>;
    pub fn preview_import(&self, bytes: &[u8]) -> CoreResult<ImportReport>;
    pub fn apply_import(&mut self, bytes: &[u8]) -> CoreResult<ImportReport>;
}
```

`export_bytes`/`preview_import` take `&self`: exporting and previewing never
write. `apply_import` takes `&mut self` like every other mutation.

## 8. Dependency: `csv`

Pinned in `[workspace.dependencies]` (`csv = "1.4.0"`). RFC 4180 quoting
— correctly handling embedded commas, quotes (doubled), and *embedded
CRLF/LF newlines inside a quoted field* — is easy to get subtly wrong by
hand, and this is exactly the kind of parsing code where a hand-rolled
version tends to work on the happy path and misparse the edge cases the
test list calls out (embedded newlines, unicode, emoji). `csv` is small,
has no heavyweight dependencies of its own beyond `csv-core`/`ryu`, and is
the de facto standard choice in the Rust ecosystem. Both the BOM prefix and
the CRLF record terminator are still handled explicitly by this crate's
code (`csv::WriterBuilder::terminator`, a manual BOM byte prefix, and a
manual BOM strip on read) rather than assumed from the library.

## 9. Trade-offs (CSV is lossy by design)

- No deleted items (§2).
- No reminder settings beyond the resolved deadline and its derived state —
  no verbatim `--in`/`--at` text, no offset, no generation.
- No exact round-trip guarantee for rows without an id: an id-less row's
  identity is `(text, created_at)`, which two genuinely different notes can
  share by coincidence (an empty `created_at` column makes every row of that
  file always-new, by design — see §4).

None of this applies to the JSON backup, which is the format to reach for
whenever fidelity matters more than opening the file in a spreadsheet.
