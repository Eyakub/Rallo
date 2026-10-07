# Rallo architecture

Rust core and CLI, SQLite, UniFFI, and a native Swift/AppKit/SwiftUI app with
Core Animation. No Tauri, React, webview, HTTP listener, daemon, privileged
helper, or LLM. macOS first; Linux and then Windows are later releases.

Rallo was built from an internal product/engineering specification that is
not published; code comments citing "plan §N" refer to its sections. This
document records what is actually built and the final names of interfaces.

## Processes

```text
shell / agent ──► rallo (CLI, Rust) ──────────────┐ Darwin notify hint / open -g
                     │                            ▼
                     ▼                     Rallo.app (Swift/AppKit)
               rallo-core (Rust) ◄─UniFFI─► CoreWorker (serial queue)
                     │                     PetPanel · NotesPanel · menu bar
                     ▼                     NotificationCoordinator
               SQLite (WAL)                       │
                                           UserNotifications (macOS)
```

- The core is a library. The CLI and the app are separate processes that open
  the same database through it.
- Only the installed app talks to UserNotifications. The CLI persists intent,
  then signals or launches the app.
- Shortcuts, Siri (App Intents) and the Services menu run inside the app
  process and save through its `CoreWorker` (`CaptureService`, 0017); macOS
  starts the app first if it isn't running.
- Swift never contains SQL or domain transitions; Rust never depends on AppKit.
  The CLI's small macOS launch adapter lives in `rallo-platform-macos`.

## Crates

| Crate | Owns |
|---|---|
| `rallo-core` | Domain rules, storage (open, pragmas, migrations, backup), IDs, text rules, preferences, instance lock, change-signal names. Injectable `Clock`. |
| `rallo-cli` | Clap parsing, JSON/human output, exit codes, post-commit app nudges. Binary name `rallo`. |
| `rallo-platform-macos` | Locating the app bundle that contains the CLI, `open -g` launch, `notify_post`, and local wall-clock time ↔ instants (`local_time`, 0016; also linked into the app through `rallo-ffi`), zip archives with `ditto`/`zipinfo` (`archive`, 0018). |
| `rallo-ffi` | UniFFI definitions (staticlib) and the pinned Swift binding generator. |

## Storage

- Path: `~/Library/Application Support/Razlio/Rallo/rallo.sqlite3`
  (directory `0700`, database and WAL/SHM `0600`). Override with
  `--data-dir` / `RALLO_DATA_DIR`; tests always use an isolated directory.
- Pragmas: `journal_mode=WAL`, `synchronous=FULL`, `fullfsync=ON`,
  `checkpoint_fullfsync=ON`, `foreign_keys=ON`, `busy_timeout=1000 ms`.
- Writes use `BEGIN IMMEDIATE` so lock waits happen at the start of short
  transactions. No native API calls or network I/O inside a transaction.
- Schema version is `PRAGMA user_version` (atomic with the migration
  transaction). A newer schema is refused with `INCOMPATIBLE_SCHEMA`; an older
  non-empty database is snapshotted with the SQLite backup API into
  `backups/` before migrating. Schema v1 stays provisional until the first
  tagged release.
- `metadata.change_revision` is a monotonic global revision bumped only when
  state actually changes. Observers read it to decide whether to reload.
- Images are files under `<data dir>/attachments/<item id>/<image id>.<ext>`
  (`0700`/`0600`), listed in the schema-v5 `attachments` table; files are
  written before their rows, and a sweep at app launch and daily removes
  images of notes deleted 30+ days ago and files no row owns (0018).
- Agent sessions are runtime state in `<data dir>/runtime/agents.sqlite3`,
  attached as `runtime`: never backed up, exported or migrated (0009).

## Single instance, signals, and launch

- **Instance/drainer lock:** `flock` on `<data dir>/app.lock`, released by the
  kernel on exit or crash. The CLI probes it (`InstanceLock::is_held`) to
  decide between signalling and launching; the app retries acquisition for up
  to 1 s at startup because a CLI probe holds the lock for an instant. A
  secondary instance forwards a show request (unless it was a background
  launch) and exits.
- **Change hints:** Darwin notifications named
  `com.razlio.rallo.{changed,show,diagnose}.<fnv1a64(data dir)>`. They carry no
  note text and are hints only; a single 1 s timer in the app (tolerance
  0.25 s) re-reads `change_revision`, so a missed signal is reconciled within
  a second.
- **Launch:** `open -g -n -a <Rallo.app> --args --background|--show --data-dir <dir>`
  with stdio detached. `-n` is required: LaunchServices otherwise keeps one
  instance per bundle and turns the request into a reopen of an instance
  that may serve another data directory; the instance lock makes surplus
  processes exit. The CLI waits for `open` to hand the request to
  LaunchServices, not for the app to finish starting. The app bundle is the
  one containing the running CLI (`Rallo.app/Contents/Helpers/rallo`, after
  resolving the PATH symlink) or `RALLO_APP_PATH` in development — never a
  shell command.
- **Reopen events:** a reopen counts as a user request (open the notes panel)
  only when its sender resolves to a running GUI application such as
  Finder; anything else is ignored so it can never override a hide.

## Threading (app)

- All core calls run on `CoreWorker`, one serial `DispatchQueue`; rusqlite is
  synchronous and there is no Rust async runtime.
- AppKit, Core Animation, and SwiftUI work stays on the main thread
  (`@MainActor` coordinator).
- Native notification effects will be serialized by an explicit single-drainer
  queue in M2; M0 has only the characterization probe.

## FFI surface (M0)

Generated Swift from `crates/rallo-ffi` (module `rallo_ffi`, C module
`rallo_ffiFFI`). Final M1/M2 operations are added here as they land.

| Swift | Rust | Notes |
|---|---|---|
| `coreInfo() -> CoreInfo` | `core_info` | core version, schema version, JSON contract version |
| `resolveDataDir(explicit:) throws -> String` | `resolve_data_dir` | explicit > `RALLO_DATA_DIR` > default |
| `changeSignalName` / `showSignalName` / `diagnosticsSignalName(dataDir:)` | same | Darwin notification names |
| `tryAcquireInstanceLock(dataDir:) throws -> InstanceLock?` | `try_acquire_instance_lock` | lock lives as long as the object |
| `RalloStore.open(dataDir:) throws` | `RalloStore::open` | opens and migrates under the SQLite write lock |
| `changeRevision() throws -> Int64` | | cheap revision read |
| `createNote(text:) throws -> ItemSnapshot` | | validated at the boundary; durable on return |
| `createReminder(text:when:) throws -> ItemSnapshot` | `create_reminder` | `when` read as for `remind --at` (RFC 3339, else a 0016 phrase); note and reminder in one write, so a refused time saves nothing (0017) |
| `listOpenItems(limit:) throws -> [ItemSnapshot]` | | newest first, capped at 50 |
| `completeItem` / `reopenItem` / `editItemText(id:…ifRevision:)` | | `ifRevision` is the row's snapshot; a newer write → `REVISION_CONFLICT` |
| `deleteItem` / `restoreItem(id:ifRevision:)` | | soft delete; restore never re-enables the reminder |
| `remindIn(id:duration:ifRevision:)` / `remindAt(id:rfc3339:ifRevision:)` | `reschedule` | creates or moves the reminder; capacity 32 enforced in core |
| `resolveReminderTime(text:nowMs:) throws -> Int64` | `resolve_reminder_time` | free function; a typed time → `deadline_ms` in the Mac's time zone, or `INVALID_TIME` with a hint; the panel's Custom… preview (0016) |
| `exportToFile(path:format:overwrite:) throws -> ExportResult` | `export_to_file` | JSON backup or CSV (0004); atomic, mode 0600 |
| `previewImportFile(path:) throws -> ImportSummary` | `inspect_import` | writes nothing; conflicts reported in the summary, not thrown |
| `applyImportFile(path:) throws -> ImportSummary` | `apply_import` | snapshot first, then one transaction; any conflict aborts before writing |
| `petVisibility()` / `setPetVisibility(visibility:)` | | `nil` = never introduced; setters return whether state changed |
| `petPlacement()` / `setPetPlacement(placement:)` | | global AppKit points; `nil` resets to default |
| `onboardingCompleted()` / `setOnboardingCompleted()` | | |
| `notificationIdentifierPrefix() -> String` | `notification_prefix` | `rallo.reminder.<scope>.`; Swift filters `UNUserNotificationCenter` requests to it before reporting them |
| `notificationAuthorization() throws -> NotificationAuthorization` | `notification_authorization` | last-observed authorization; `notDetermined` before the first drain pass |
| `recordNativeObservations(authorization:pending:delivered:) throws -> CleanupPlan` | `record_native_observations` | 0005 drain-pass step 1; `pending`/`delivered` are this store's own `NativeRequest`s |
| `nextPlatformWork() throws -> NextWork` | `next_platform_work` | mutating: may abandon elapsed schedule intents; `.work(PlatformWork)` or `.idle(nextWakeAtMs:)` |
| `beginPlatformAttempt(intentId:generation:) throws -> BeginOutcome` | `begin_platform_attempt` | `.started(AttemptToken)` or `.superseded`; commits before any native effect |
| `finishPlatformAttempt(token:outcome:) throws -> Finished` | `finish_platform_attempt` | compare-and-set on the token; `NativeOutcome` reports what the native call did |
| `applyNotificationAction(reminderId:generation:action:) throws -> ActionOutcome` | `apply_notification_action` | `.applied(ItemSnapshot)` or `.stale(item:reason:)` for a tapped `rallo.done`/`rallo.snooze.10m` |
| `acknowledgeReminder(id:ifRevision:) throws -> ItemSnapshot` | `acknowledge` | wraps 0003's `acknowledge`; already-inactive is a no-op |
| `snoozeReminder(id:duration:ifRevision:) throws -> ItemSnapshot` | `snooze` | `--in` syntax only; requires an existing reminder |
| `petSnapshot() throws -> PetSnapshot` | `pet_snapshot` | cheap read-only projection (`open_count`, `due_count`, `next_due_at_ms`, `completion_seq`, `save_seq`) for `decidePet`'s input |
| `decidePet(inputs:) -> PetDecision` | `pet::decide` | free function; pure priority-table reducer (0006), no store access |
| `petAnimationsPaused()` / `setPetAnimationsPaused(paused:)` | | menu-bar "pause animation"; setters return whether state changed |

`ItemSnapshot.reminder` carries the deadline, state, and the core's
scheduling status (`schedulingState`, e.g. `pending` / `awaiting_app` until the
app has scheduled it); Swift displays it and never derives it. The full
scheduling/cancellation status table and the notification protocol's types are
specified in `docs/decisions/0005-notification-protocol.md`.

Errors cross as `RalloError` with a stable `code` string:
`InvalidInput`, `NotFound`, `Conflict` (e.g. `REVISION_CONFLICT`),
`Storage` (`STORAGE_UNAVAILABLE` / `STORAGE_BUSY`),
`IncompatibleSchema(found, supported)`.

## Build pipeline

- `scripts/build-rust.sh` builds the static library, generates bindings
  (`scripts/generate-bindings.sh`), and builds the CLI. The Xcode pre-build
  phase runs it; files in `apps/macos/Rallo/Generated/` are replaced only when
  their content changes and are never edited or committed.
- `apps/macos/project.yml` (XcodeGen) is the source of truth for the Xcode
  project; `Rallo.xcodeproj` is generated and gitignored.
- The post-build phase embeds and signs the CLI at `Contents/Helpers/rallo`
  (a case-insensitive filesystem cannot hold both `MacOS/Rallo` and
  `MacOS/rallo`).
- `scripts/build-macos.sh [--install]` produces the Release app and optionally
  installs it to `~/Applications/Rallo.app`.

### Toolchain interoperability (found in M0)

- **Release LTO is off.** With `lto = "thin"`, the staticlib's objects carried
  LLVM 22 bitcode that Xcode 26.3's toolchain (Apple LLVM 17) could not read,
  and the link failed.
- **The archive index is rebuilt with `xcrun ranlib`.** Even with native
  objects, Xcode's `ld` reported undefined symbols that `nm` showed were
  present and indexed; rewriting the index with Xcode's `ranlib` fixed it. The
  build stages a ranlib'd copy in `build/rust/lib/`, and Xcode links only that
  copy.
