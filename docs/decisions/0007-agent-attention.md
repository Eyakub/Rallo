# 0007 — Agent attention: the pet tells you when an agent needs you

- **Status:** accepted (user, 2026-10-01). A feature beyond the build plan;
  it keeps the plan's rules: local only, no network, no global input
  monitoring, the reducer decides *what*, Swift decides *how* (0006).
- **Date:** 2026-10-01

Coding agents (Claude Code, Codex) often sit idle waiting for a permission
answer while the user is in another window. Both run hook commands at
lifecycle events. Rallo installs one hook command; the pet waves when an
agent waits for the user, shows a ✓ when one finishes, and the notes panel
lists them, with a click bringing that agent's terminal app forward.

## Sources and the event mapping

Both agents run a command with one JSON object on stdin. Measured on Codex
CLI 0.158 (`~/.codex/hooks.json`, same schema as Claude Code's
`~/.claude/settings.json` `hooks`): every payload has `session_id`,
`hook_event_name`, `cwd`; `UserPromptSubmit` carries the full `prompt` and
`Stop` the `last_assistant_message`. **Neither is ever stored.**

| Hook event | Agent | Rallo state |
|---|---|---|
| `PermissionRequest` | both | `waiting` (detail: `tool_name`) |
| `Notification` with `notification_type` `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, or `agent_needs_input` | Claude Code | `waiting` |
| `PostToolUse`, `UserPromptSubmit` | both | `working` (clears waiting/done; written only on change) |
| `Stop`; `Notification` `idle_prompt` or `agent_completed` | both / Claude Code | `done` (no-op if already done) |
| `SessionEnd`, `Interrupt` | both / Codex | row deleted |
| anything else | — | ignored |

Only `hook_event_name`, `session_id`, `cwd`, `notification_type`, and
`tool_name` are read; everything else in the payload is ignored, so field
additions in either agent don't matter. Claude Code documents that exit 2
blocks `Stop` and `UserPromptSubmit`, that `SessionEnd` hooks share a 1.5 s
budget, and that plain stdout of these events is not added to the model's
context (it is for `UserPromptSubmit`/`SessionStart`).

`PostToolUse` matters: after the user approves a permission request in the
terminal, no hook says so; the next tool finishing does.

## Storage (schema v3)

Migration `0003_agent_sessions.sql`, taken with the usual pre-migration
backup:

```sql
CREATE TABLE agent_sessions (
  agent         TEXT NOT NULL CHECK (agent IN ('claude', 'codex')),
  session_id    TEXT NOT NULL CHECK (length(session_id) BETWEEN 1 AND 200),
  state         TEXT NOT NULL CHECK (state IN ('working', 'waiting', 'done')),
  cwd           TEXT CHECK (cwd IS NULL OR length(cwd) <= 4096),
  detail        TEXT CHECK (detail IS NULL OR length(detail) <= 120),
  app_path      TEXT CHECK (app_path IS NULL OR length(app_path) <= 4096),
  app_pid       INTEGER,
  state_seq     INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (agent, session_id)
) STRICT, WITHOUT ROWID;
```

- `detail` is built from fixed templates only: the tool name for a
  permission request ("Bash"), or nothing. Never prompt or model text.
- `state_seq` comes from a monotonic counter in the existing metadata table
  (`agents.state_seq`), bumped on every state change, so deleting rows never
  lowers it and the pet's watermarks stay valid.
- Every `agent-event` write prunes rows not updated for 24 hours.
- A change posts the usual per-data-directory change signal; the app is
  never launched for an agent event.

## Which terminal to bring forward

`agent-event` walks its ancestor processes (`proc_pidinfo`/`proc_pidpath`,
at most 32 steps) to the first one inside an `.app` bundle, and records the
outermost bundle path and that process's pid (e.g. Terminal, iTerm2, cmux,
VS Code). Without one (tmux server, SSH), `app_path` is `NULL` and the row
just isn't clickable. Swift activates the running app with that bundle, or
opens it. It brings the app forward, not the exact tab: tabs need per-app
Automation permission.

## CLI

- `rallo agent-event --agent claude|codex` reads the hook JSON from stdin.
  **Always exits 0 and prints nothing to stdout** (Claude Code adds some
  hooks' stdout to the model's context; a failing hook can block the
  agent). Problems go to stderr. Payload fields are length-checked; unknown
  events are ignored. Target: ≤ 50 ms p95.
- `rallo agents [--json]` lists current sessions; `rallo agents clear
  [--agent A] [--session ID]` removes rows.
- `rallo setup hooks [--agent claude|codex]… [--remove] [--print]`:
  - Claude Code: merges into `~/.claude/settings.json` `hooks`; Codex:
    `$CODEX_HOME/hooks.json` (default `~/.codex`). Default: every detected
    agent, as `setup skill` does.
  - The command is the installed app's CLI by absolute path
    (`"…/Rallo.app/Contents/Helpers/rallo" agent-event --agent X || true`:
    both agents run hooks through a shell, and `|| true` means an older CLI
    without `agent-event`, which exits 2, can't block `Stop`), because
    hooks run without the user's interactive PATH. Refuses (`NOT_INSTALLED`)
    from a copy that isn't in an installed app.
  - Rallo's entries are recognised by that command shape. Re-running
    replaces them; `--remove` deletes only them (and arrays it emptied).
    Everything else in the file, including key order, is kept.
  - Before the first change to a file it saves `<file>.rallo-backup`; writes
    are atomic. A file that isn't valid JSON is refused, untouched.
  - Codex asks the user to trust new hooks (their hash lives in
    `config.toml`); Rallo never writes trust itself and says so.
  - `--print` shows the entries it would add.
- `doctor` gains `agent_hooks` (after `agent_skill`): optional, `ok` when
  absent, a warning when Rallo's entries point at a different CLI path.

## Pet (extends 0006)

`PetSnapshot` adds `agents_waiting` (fresh `waiting` rows),
`agent_waiting_seq`, `agent_done_seq`; `PetInputs` adds
`seen_agent_waiting_seq`, `seen_agent_done_seq` (initialized to current at
startup, like the others).

- `agents_waiting > 0` → pose `Due` (someone needs the user), like a due
  reminder.
- `Attention` when `agent_waiting_seq > seen` (each new waiting agent), or on
  the reminder rising edge as before.
- `Acknowledge` (happy face + ✓) when `agent_done_seq > seen` and not due.
- Accessibility label: "…, 2 agents waiting".
- Swift draws a second badge for waiting agents (blue, top left) beside the
  reminder badge (orange, top right). Reduce Motion/Pause Animations apply
  unchanged.

## Panel

An "Agents" section above the notes when any `waiting`/`done` row is fresh:
"Claude Code · rallo — Waiting for permission: Bash · 2 min", waiting first.
Clicking a row brings its app forward; ✕ removes it. `working` rows are not
shown.

## Not doing

Banners for agent events (the pet is the signal), exact-tab focusing, other
agents until their hooks are verified, any network or remote relay.
