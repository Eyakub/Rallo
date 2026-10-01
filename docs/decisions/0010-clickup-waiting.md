# 0010 — ClickUp messages waiting for your reply

- **Status:** accepted (user, 2026-10-01). Extends 0007–0009's "waiting for
  you" from coding agents to people. Amends the local-only rule: Rallo uses
  the network only for `rallo update` and for a connector the user turns on,
  and then talks only to that service.
- **Date:** 2026-10-01

Someone messages the user on ClickUp while they're heads-down; ClickUp's own
banner is gone in seconds. The pet and the "Waiting for you" section already
say who needs the user; a ClickUp conversation waiting for a reply is the
same kind of thing.

## No server: Rallo asks ClickUp

Claude Code and Codex run on the Mac and call Rallo through a hook. ClickUp
runs on ClickUp's servers; its webhooks need a public HTTPS endpoint, which a
Mac app doesn't have. So the app polls ClickUp's API (v3 chat) from the Mac,
once a minute, while connected.

Measured on a real workspace (57 chats): the documented per-chat `counts`
(`has_unread`, `num_unread`, `mention_count`) are not returned, and DMs have
no `name`. What works: `with_message_since` returns the chats with recent
messages, and a chat's latest message carries `user_id`.

## The rule

A **direct or group message whose latest message is someone else's**, within
the last 24 hours, is waiting for the user. It clears when they reply.
Channels (and @mentions in them) are not covered yet. Read state isn't
available, so Rallo can't see you reading it in ClickUp; opening the
conversation from Rallo, ✕, or a swipe dismisses the row (below).

Per check: one channel listing, plus one "latest message" request for each
conversation whose `latest_comment_at` changed since the last check. A quiet
minute costs one request (ClickUp allows 100 per minute per token). A 429
skips 1, 2, 4… up to 16 checks; a 401 stops polling, clears the rows, and
says so in the menu. Offline or asleep: the next minute retries.

## Connecting

- Menu: **Connect ClickUp…** asks for a personal API token (ClickUp →
  Settings → Apps; it starts with `pk_`), checks it against `GET /v2/user`,
  and keeps it in the login Keychain (service `rallo-clickup-token`). A token
  already stored there under that name is picked up at launch.
- **Disconnect ClickUp** deletes the token and the ClickUp rows.
- The first workspace the token can see is watched.
- The token can read and change the whole ClickUp account (ClickUp has no
  scoped personal tokens). It is never written to the database, logs, or
  files. Rallo only sends GET requests and never stores message text: a row
  holds the sender's name, whether it's a group, and the conversation id.
- Requests go through an ephemeral `URLSession` with no cache and no cookie
  store, so no ClickUp response reaches disk whatever its headers say. The
  diagnostics log gets error codes only (a URL error's text would carry the
  workspace and conversation ids).
- An ad-hoc-signed app's Keychain access is tied to its exact build, so
  macOS asks again ("Always Allow") after each update.

## Storage

The rows go into 0009's runtime `agent_sessions` (runtime layout v2 allows
`agent = 'clickup'`): `session_id` = conversation id, `place` = sender name,
`detail` = `group` or NULL, `focus` = `clickup:<workspace>:<conversation>`,
`updated_at_ms` = the latest message's time, no agent process. Each check
replaces the ClickUp rows wholesale (`sync_clickup_waiting`): a new
conversation or a newer message bumps `agents.state_seq`, so the pet waves;
an unchanged list is a no-op.

Dismissing (✕, a swipe, or opening the conversation from the panel or menu)
sets a ClickUp row's state to `dismissed` (runtime layout v3) instead of
deleting it, since the next poll would re-add it; only a newer message
makes it `waiting` again. Lists and the pet count `waiting` rows only.
Dismissing an agent session still deletes it.

## Showing it

- Panel and menu ("Waiting for You"): "Muhsin Ahmed — Messaged you on
  ClickUp · 2 min". The pet's badge and wave count them with agents; its
  accessibility label now says "N waiting for you".
- A click opens the conversation: `clickup://app.clickup.com/<workspace>/chat/r/<id>`
  in the desktop app (it maps that to the web address), else the web
  address, and dismisses the row.
- Any row in the panel (agent or ClickUp) can be swiped away: a two-finger
  trackpad swipe or a click-drag past 90 pt dismisses it; shorter springs
  back. Vertical scrolling and mouse wheels pass through. Reduce Motion
  drops the slide animation.
- No Rallo banner: ClickUp sends its own, and the 5-minute long-wait banner
  (0008) stays for agents only.
- `rallo agents` lists them (`"agent": "clickup"`).

## Not doing (yet)

Channel @mentions (would mean scanning message text for the user's id),
task comments and assignments (no inbox API), more than one workspace,
OAuth (needs a server for the client secret).
