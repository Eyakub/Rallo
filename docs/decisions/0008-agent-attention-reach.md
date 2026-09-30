# 0008 — Agent attention beyond the pet: menu bar, long waits, shortcuts

- **Status:** accepted (user, 2026-10-01). Extends 0007; same rules (local
  only, no input monitoring, no stored prompt or model text).
- **Date:** 2026-10-01

The pet can be hidden, covered by a full-screen app, or out of sight while
the user is away. Three additions make a waiting agent hard to miss, and one
fixes a keyboard gap (the panel had no keyboard route besides ⌃F8 → menu).

## Menu bar

- The status item shows the paw plus the number of waiting agents ("🐾 2"),
  paw only at 0. Its tooltip lists them, one line each:
  "Claude Code · shop — Waiting for permission: Bash (4 min)".
- The status menu starts with an "Agents" section when any session is
  waiting or done (same rows and order as the panel, 0007): choosing one
  brings its terminal forward; nothing is dismissed from the menu.

## Long-wait notification (opt-in)

- Menu item "Notify When an Agent Waits 5 Minutes", off by default, stored
  as the preference `agents.notify_long_wait` (bool) in the store, like
  `pet.animations_paused`.
- When a session has been `waiting` for 5 minutes (from its `updated_at_ms`)
  and the preference is on, Rallo posts one local notification per waiting
  period: "Claude Code is waiting in shop — Waiting for permission: Bash".
  Its identifier is `rallo.agent.<data-dir scope>.<agent>.<session>`, a
  namespace the reminder reconciler (0005, `rallo.reminder.…`) never
  touches. It is withdrawn (pending and delivered) as soon as the session
  leaves `waiting` or is dismissed.
- Clicking it brings the terminal forward. Notification permission is the
  same one reminders use; without it nothing is posted and the menu item
  says why.
- "Once per waiting period" is kept in memory keyed by `(agent, session,
  state_seq)`; after an app restart a still-waiting session may notify once
  more. Accepted.

## Shortcuts

Carbon `RegisterEventHotKey` (no Accessibility or Input Monitoring
permission; Rallo sees only its own two key combinations):

- **⌃⌥⌘J** brings the longest-waiting agent's terminal forward; pressing it
  again within 5 s moves to the next waiting one, then to finished ones.
  With no sessions, nothing happens.
- **⌃⌥⌘N** opens the notes panel with the new-note field focused, or closes
  it if open (same as clicking the pet).
- ⌃⌥⌘ because plain ⌃⌥ letters collide with window managers (Rectangle uses
  ⌃⌥U/I/J/K). If registration fails (another app owns the combination), the
  menu shows the item without the shortcut and a "(shortcut in use)" note.
  The menu items show the shortcuts.

## VoiceOver

When a session enters `waiting` (a new `agent_waiting_seq`) and VoiceOver is
running, the app posts an accessibility announcement: "Claude Code in shop
is waiting for permission: Bash."

## Not doing

Configurable shortcuts, a configurable wait threshold (5 minutes), banners
for finished agents, per-tab focusing (see 0007).
