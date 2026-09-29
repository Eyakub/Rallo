# CLI contract

`rallo` is the same interface for people and agents. This file documents what
is implemented; the full canonical command set is in section 5 of
`rallo-macos-build-plan.md` and lands over M1–M4.

## Implemented (M0)

| Command | Behaviour |
|---|---|
| `rallo note TEXT` / `rallo note --stdin` | Durably stores an open note, then (only if the pet is visible) signals or background-launches the app without waiting for it. `--stdin` drops exactly one trailing line ending; all other content is stored verbatim. |
| `rallo list` | Open, nondeleted notes, newest first, first 50. Never starts the app. |
| `rallo show [--reset-position]` | Persists "visible", then signals a running app or launches it with `open -g` (no activation). |
| `rallo hide` | Persists "hidden" and signals a running app. Never launches it. |
| `rallo status` | App running (instance lock), data directory, schema, revision, pet visibility. Never starts the app. |
| `rallo --version [--json]` | CLI, core, database schema, and JSON contract versions. |

Global options: `--json`, `--data-dir DIR` (or `RALLO_DATA_DIR`).

## Output

- `--json` writes exactly one JSON document to stdout with
  `schema_version` (JSON contract version, currently `1`), `ok`, the command's
  fields, and `warnings`. Failures write `{"ok": false, "error": {"code", "message"}}`.
  No ANSI sequences. Keys are sorted.
- Human output goes to stdout; diagnostics, warnings, and help go to stderr.
- Stored text is shown with control characters and bidi overrides replaced by
  U+FFFD and line breaks flattened. JSON output is lossless.
- `SIGPIPE` has its default behaviour (`rallo list | head` ends quietly).

## Input rules

- Note text: non-empty after trimming, at most 64 KiB of UTF-8. Invalid UTF-8
  on stdin is rejected. Stdin is read only with `--stdin`.
- No interactive prompts in data commands.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success / committed |
| 2 | Invalid arguments or input (nothing committed) |
| 3 | Not found |
| 4 | Conflict / ambiguous (M1) |
| 5 | Storage failure or lock timeout |
| 6 | Installation/platform failure for platform-only commands (e.g. `show` when the app cannot be found) |
| 7 | Incompatible schema |

A saved note whose app nudge failed still exits 0 and reports the problem in
`warnings`.
