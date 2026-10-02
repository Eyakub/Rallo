# 0013 — Voice typing (experimental)

- **Status:** prototype, pending user review.
- **Date:** 2026-10-02

## Context

People want to type by voice anywhere: a terminal, a browser, any app. The pet
is always visible, so it is a natural place to show that Rallo is listening.

## Decision

Settings → General has "Voice typing (⌃⌥⌘V)", marked experimental, **off by
default**, and disabled before macOS 26.

- **Shortcut toggle, not a pet click.** A pet click opens Notes. ⌃⌥⌘V starts
  listening and the same press stops it; it also stops after 10 s with no new
  speech result. The hotkey is registered only while the feature is on, so it
  isn't taken from other apps otherwise.
- **Engine.** Apple's `DictationTranscriber` (Speech framework, macOS 26+),
  on-device, with punctuation. macOS may download its speech model the first
  time; the bubble says so.
- **Only finals are typed.** A bubble above the pet (a non-activating,
  click-through panel with the pet's level and collection behaviour, 0002)
  shows "Listening…" and then the live, still-changing words. Each finalized
  phrase is typed into the focused app.
- **Synthetic keystrokes with modifier flags cleared**, in chunks of at most 16
  UTF-16 units that never split a character, so the still-held ⌃⌥⌘ never
  turns text into shortcuts.
- **Never newlines.** Newlines, carriage returns, and tabs become spaces, so
  voice typing can't press Return or Tab (and run a command) in a terminal.
- **Secure input is respected.** If secure event input is on (password
  fields), nothing is typed and the bubble says so.
- **Permissions.** Microphone and Accessibility (to post keystrokes). If one
  is missing, the bubble says where to allow it and listening doesn't start.
  Signing per 0012 keeps both grants across updates.
- **Privacy.** Audio and transcripts are never stored or logged; the
  diagnostics log records only `voice_started`, `voice_stopped` (with a
  reason), and `voice_failed` (error type).

See [0014](0014-whisper-engine.md) for the Whisper engine and the Voice tab.

## The pet listens

Once the microphone is live the pet cross-fades into `pet-listening` (paw
cupped to a perked ear) and loops a slow lean toward that ear with a soft
breath; each typed phrase gets a small upward bob. A wave or hop already in
progress finishes first. On stop it fades back to whatever it would show
otherwise. Play reactions and ambient poses pause while it listens, and
Reduce Motion, Pause Animations or an occluded pet keep the pose but drop
the motion.

## Not done yet

AI cleanup of the text, per-app rules and a configurable
shortcut.
