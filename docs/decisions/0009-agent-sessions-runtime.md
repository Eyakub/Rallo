# 0009 — Agent sessions are runtime state; jump to the exact pane

- **Status:** accepted (user, 2026-10-01). Amends 0007's storage and "which
  terminal to bring forward"; same rules (local only, no network, no
  stored prompt or model text).
- **Date:** 2026-10-01

0007 kept agent sessions in the notes database. They aren't notes: they
mean something only while the agent runs, yet they went into every backup
and pre-migration snapshot, stored full working-directory paths, and lived
until a 24 h prune even after the terminal was closed.

## Storage: a throwaway runtime file

- Schema v4 (`0004_agent_sessions_to_runtime.sql`) drops `agent_sessions`
  from `rallo.sqlite3`.
- Sessions live in `<data dir>/runtime/agents.sqlite3` (0700 folder, 0600
  file, WAL), attached to every store connection as `runtime`. It is never
  backed up (the backup API copies `main` only), exported, or migrated: a
  layout from another version (`PRAGMA runtime.user_version`) is dropped and
  recreated. The app marks the folder excluded from Time Machine.
- `agents.state_seq` stays in the notes database's `metadata`, so recreating
  the runtime file never lowers a watermark the pet has seen.

```sql
CREATE TABLE runtime.agent_sessions (
  agent, session_id, state ('working' | 'waiting'),
  place,            -- last two folders of cwd, "~" for home
  detail,           -- tool name, or NULL
  app_path, app_pid,
  focus,            -- "cmux:<workspace>:<panel>" or "tty:/dev/ttysN"
  agent_pid, agent_started_us,
  state_seq, updated_at_ms,
  PRIMARY KEY (agent, session_id)
) STRICT, WITHOUT ROWID;
```

## A row lives as long as its agent

- `agent-event` records the agent process: the nearest ancestor that isn't
  a shell (sh, bash, zsh, dash, fish, ksh, csh, tcsh) or `rallo`, with its
  start time in µs (pid alone can be recycled).
- Rows whose process is gone, or idle for 24 h (backstop for rows without a
  process), are pruned on every hook write and before every read
  (`rallo agents`, the app's sessions list and pet snapshot). A prune bumps
  the change revision, so every view reloads.
- While any agent waits, the app reads sessions every 30 s, so closing a
  terminal without a clean exit clears its row within half a minute.
- A resumed session that comes back under a new process follows it quietly
  (no pet-visible change).

## Jump to the exact pane

The hook stores a `focus` target; a row click (or ⌃⌥⌘J) first brings the
app forward as before, then:

| Terminal (bundle id) | Focus | Action |
|---|---|---|
| cmux (`com.cmuxterm.app`) | `cmux:` from `CMUX_WORKSPACE_ID`/`CMUX_PANEL_ID` | `<app>/Contents/Resources/bin/cmux select-workspace`, then `focus-panel` |
| Terminal (`com.apple.Terminal`) | `tty:` from the agent's controlling terminal | AppleScript: select the tab whose `tty` matches, raise its window |
| iTerm2 (`com.googlecode.iterm2`) | same | AppleScript: select the window, tab and session whose `tty` matches |
| anything else | — | the app only |

- IDs are checked (`[A-Za-z0-9-]{1,64}`, `/dev/ttys` + digits) when written
  and again before use; the tty is passed to `osascript` as an argument,
  never spliced into the script.
- Terminal and iTerm2 need Automation permission: the app is signed with
  `com.apple.security.automation.apple-events` and explains itself in
  `NSAppleEventsUsageDescription`; macOS asks once per terminal. Declined,
  a closed tab, or cmux's socket off: the app is already in front.

## Pet

`agent_done_seq`/`seen_agent_done_seq` (inert since 0007's amendment) are
removed from `PetSnapshot`/`PetInputs`.

## CLI

`rallo agents --json` rows carry `place` and `focus` instead of `cwd`.
`rallo agents` posts the change signal when its prune removed a row.
