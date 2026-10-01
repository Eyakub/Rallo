# Platform support

Platform facts, measured results, and design assumptions are kept separate.
Nothing here claims support that has not been verified.

## Status

| | Status |
|---|---|
| Target | macOS 14+ on Apple Silicon (initial validation) |
| Verified OS | macOS 27.0 (26A428) and 27.0.1 (26A434) |
| Minimum OS (14.0) | **Not yet validated** — no macOS 14 environment available |
| Intel (x86_64) | **Not supported.** The Rust target is installed and code is kept buildable, but nothing has been built or tested on Intel hardware. The first release will be labelled Apple Silicon unless Intel testing happens. |
| Signing | Ad-hoc only (no Developer ID identity on the build machine). Not notarized. |
| Distribution | GitHub Releases of the private repository, v0.1.0 (`distribution.md`) |

## Verified environment

| Item | Value |
|---|---|
| Hardware | MacBook Pro `Mac15,6`, Apple M3 Pro (5P + 6E cores), 18 GB |
| OS | macOS 27.0, build 26A428 |
| Displays during M0 | external 1920×1080 primary + external 1920×1080 (+ built-in Retina, intermittently) |
| Stage Manager | off (not changed by tests) |
| Xcode / SDK | Xcode 26.3 (17C529), macOS SDK 26.2 |
| Swift | 6.2.4 (language mode 5) |
| Rust | 1.98.1 stable (`aarch64-apple-darwin`) |
| Install location tested | `~/Applications/Rallo.app` |

## Product limits (design decisions, not platform claims)

- **32 active reminders.** A conservative MVP product boundary, *not* an Apple
  limit. Active means enabled and unacknowledged, including overdue
  reminders awaiting action. Undated notes, acknowledged/cancelled reminders,
  and completed/deleted items do not count. Notes have no count limit.
  See `reminder-semantics.md` for the M0 capacity measurements behind it.
- Note text: 64 KiB of UTF-8.
