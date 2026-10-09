# 0020 — Update badge and default-on check

- **Status:** accepted (user, 2026-10-10). Amends 0011: the daily check is on
  by default, and a pending update badges the menu bar paw.
- **Date:** 2026-10-10

## Context

Users miss that an update exists: the "Update to Rallo X…" item is only
visible while the menu is open, and the check was off unless they found the
setting.

## Decision

- The daily check is on unless the user turned it off. An unset
  `updateCheckEnabled` means on; a stored `false` stays off.
- While `UpdateChecker.available` is non-nil, the menu bar paw gets a badge: a
  template `arrow.down.circle.fill` overhanging the paw's bottom-right corner,
  with a thin gap punched out around it. It is one template image, so the menu
  bar colours it. It clears when the update is installed, the check finds none,
  or the check is turned off.
- The tooltip gets a first line `Rallo — update available (X)` above the agent
  list. VoiceOver reads "Rallo, update available".
- The "Update to Rallo X…" menu item has no icon: an `NSMenuItem` image did
  not render in the status menu on macOS 27 (the gear on Settings… is drawn
  by the system).
- `RALLO_PREVIEW_UPDATE=<version>` fakes an available update, only in a
  scratch instance (non-default data dir), so the installed app can't be faked.

## Consequence

Without opting in, the app sends one GitHub request about 30 s after launch and
then daily (what 0011 describes under "What is sent"). Scratch and `--data-dir`
instances still never check.
