# Rallo architecture

Rust core and CLI, SQLite, UniFFI, and a native Swift/AppKit/SwiftUI app with
Core Animation. No Tauri, React, webview, HTTP listener, daemon, privileged
helper, or LLM. macOS first; Linux and then Windows are later releases.

The authoritative product/engineering specification is
`rallo-macos-build-plan.md`. This document records what is actually built and
the final names of interfaces.

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
- Swift never contains SQL or domain transitions; Rust never depends on AppKit.
  The CLI's small macOS launch adapter lives in `rallo-platform-macos`.

## Crates

| Crate | Owns |
|---|---|
| `rallo-core` | Domain rules, storage (open, pragmas, migrations, backup), IDs, text rules, preferences, instance lock, change-signal names. Injectable `Clock`. |
| `rallo-cli` | Clap parsing, JSON/human output, exit codes, post-commit app nudges. Binary name `rallo`. |
| `rallo-platform-macos` | Locating the app bundle that contains the CLI, `open -g` launch, `notify_post`. |
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
| `listOpenItems(limit:) throws -> [ItemSnapshot]` | | newest first, capped at 50 |
| `petVisibility()` / `setPetVisibility(visibility:)` | | `nil` = never introduced; setters return whether state changed |
| `petPlacement()` / `setPetPlacement(placement:)` | | global AppKit points; `nil` resets to default |
| `onboardingCompleted()` / `setOnboardingCompleted()` | | |

Errors cross as `RalloError` with a stable `code` string:
`InvalidInput`, `NotFound`, `Storage` (`STORAGE_UNAVAILABLE` / `STORAGE_BUSY`),
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
