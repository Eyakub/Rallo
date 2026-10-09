# 0002 — Pet window configuration

- **Status:** Accepted (M0). Changes require a new decision record.
- **Date:** 2026-09-30
- **Owner files:** `apps/macos/Rallo/Pet/PetWindow.swift` (`PetPanel` lives there)

The pet window's behaviour is decided once, here. Features must not adjust
its level or collection behaviour ad hoc.

## Decision

| Property | Value | Why |
|---|---|---|
| Class / style | `NSPanel`, `[.borderless, .nonactivatingPanel]` | Clicking the pet never makes Rallo the active app and never disturbs the frontmost app's text cursor. |
| `isFloatingPanel` | `true` | Stays above ordinary document windows. |
| `hidesOnDeactivate` | `false` | Remains visible while another app is frontmost (Rallo is almost never frontmost). |
| `canHide` | `false` | Stays when Rallo is hidden (⌘H, or Hide Others from another app while the notes window makes Rallo a Dock app). |
| `level` | `.statusBar` (raw 25) | Default from the spec. Not escalated further to force visibility on surfaces that decline it. Fallback is `.floating` if real use shows `.statusBar` covers surfaces it should not. |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` (raw 337) | Follows the user across Spaces; *permitted* (not guaranteed) over other apps' full-screen Spaces; not rearranged by Mission Control/Exposé; excluded from ⌘\` cycling. |
| `canBecomeKey` / `canBecomeMain` | `false` / `false` | A passive pet never takes keyboard focus. |
| Opaque / background / shadow | `false` / `.clear` / none | Sprite-shaped presence. |
| Size | 112 × 92 pt, the sprite bounds | Avoids a large invisible rectangle blocking other apps. No global mouse monitor is used to simulate click-through. |
| Activation on click | None for the pet itself | Clicking opens the notes panel, which is an explicit request to type and does activate Rallo (see below). |

The notes panel is a separate, ordinary titled `NSPanel` (`.floating`,
`[.moveToActiveSpace, .fullScreenAuxiliary]`) that activates Rallo and becomes
key, because the user explicitly asked to type.

### `.canJoinAllSpaces` versus `.transient`

M0 ships `.canJoinAllSpaces`. Following the user everywhere can feel intrusive
to people who separate work Spaces; `.transient` would strand the pet on the
Space where it was created, which reads as a crash. Testing so far has not
changed this choice (see 0001 for which surfaces were actually exercised).

### Surfaces expected to refuse the overlay (documented, not worked around)

Secure input fields, the login window, the screen saver, and full-screen
applications that decline auxiliary windows.

## Verified in M0

Recorded from the running installed app via its own window report
(`diagnostics/windows.json`) and `CGWindowListCopyWindowInfo`:

- level 25, collection behaviour 337, `canBecomeKey == false`, `isKeyWindow == false`;
- after a background launch from the CLI, `NSApp.isActive == false` and the
  frontmost application was unchanged;
- one pet window per data directory under ten concurrent launches.

Items not yet exercised are listed in 0001.
