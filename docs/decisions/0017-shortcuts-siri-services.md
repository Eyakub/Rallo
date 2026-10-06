# 0017 — Shortcuts, Siri and the Services menu

- **Status:** accepted (user, 2026-10-06). Amends 0016's grammar: `a.m.`/`p.m.`
  and trailing punctuation are accepted, because Siri writes them.
- **Date:** 2026-10-06

## Context

Saving a thought means typing `rallo note …` in a terminal or opening the panel
(⌃⌥⌘N). Text read elsewhere (a Slack message, a web page) takes copy, open,
paste, Enter. macOS has two standard ways in that need no new UI: App Intents
(actions in the Shortcuts app, Siri, and Spotlight on macOS 26) and the
Services menu (an item in the right-click menu of any selected text).

## Decision

### Actions (App Intents)

| Action | Parameters | Runs | Reply |
|---|---|---|---|
| **Add Rallo Note** | Note (text; Siri asks "What's the note?") | in the background (`openAppWhenRun = false`) | "Saved to Rallo." |
| **Add Rallo Reminder** | Note; When (text; Siri asks "When?") | in the background | "Reminder set for Fri 9 Oct at 5:00 PM." (`ReminderLabel`) |

- **When** is text read with 0016's rules, exactly as `rallo remind --at`:
  RFC 3339 first, then a phrase. A Shortcuts user with a Date value passes it
  formatted as ISO 8601. A phrase Rallo can't read fails the action with the
  0016 hint, which Siri speaks; nothing is saved.
- The reminder is saved in one write with its note, as `rallo remind` does
  (`Store::create_reminder`, exposed to Swift as `RalloStore.createReminder`).
- App Shortcuts (Siri phrases, also listed in Spotlight on macOS 26), English:
  "Add a note in Rallo", "New Rallo note", "Remind me in Rallo", "New Rallo
  reminder". App Shortcut phrases can't carry free text, so Siri asks for the
  note and the time.
- Feedback in Rallo itself is the pet's acknowledgement: every save already
  increments `save_seq` (0006), whoever made it.

### Services menu

- Info.plist `NSServices` declares **New Rallo Note** for plain text
  (`public.utf8-plain-text`, `NSStringPboardType`), with an empty
  `NSRequiredContext` so macOS enables it by default.
- The selected text becomes the note as-is (multi-line stays multi-line; the
  core validates it as for any note).
- Success: the pet's acknowledgement. Failure (empty selection, over 64 KB,
  storage unavailable): the notes panel opens with the error in its usual
  banner, so a failed save is never silent. The message stays until the
  panel is next opened; a reload of the list doesn't clear it.
- Rallo reads the pasteboard only when the service is invoked, and only the
  text sent with it. Like any Services item, another app on the Mac can invoke
  it with its own text (`NSPerformService`); the most it can do is add a note
  or open the panel, no more than it could with the `rallo` command.

### Startup

macOS starts Rallo if it isn't running. Actions and the Services item wait up
to 5 s for the store to open (`CaptureService`), then fail with "Rallo is
still starting. Try again in a moment." If the store fails to open, they fail
at once with "Rallo can't open its storage. Run rallo doctor in Terminal."
The Services provider is registered in
`applicationDidFinishLaunching`, so a request that launched the app is still
delivered.

### Siri transcription (amends 0016)

Before parsing, `a.m.`/`p.m.` (any case, with or without the space before
them) become `am`/`pm`, and one trailing `.`, `,` or `!` is dropped:
"Tomorrow at 9 a.m." and "fri 5pm." now resolve. Everything else in 0016 is
unchanged; other punctuation and emoji are still refused.

### Code

- `crates/rallo-core/src/reminders/phrase.rs`: the normalisation above.
- `crates/rallo-ffi`: `RalloStore::create_reminder(text, when)`.
- `apps/macos/Rallo/Capture/`: `CaptureService` (waits for the store, saves,
  turns core errors into messages), `RalloIntents` (the two intents and the
  App Shortcuts provider), `ServicesProvider` (the `newRalloNote` handler).
- `AppCoordinator` attaches the store to `CaptureService` once it opens, and
  shows a capture error in the notes panel.

## Alternatives

- **Call the embedded `rallo` CLI from the intents.** A second process and
  JSON parsing for what the FFI already does in-process.
- **A URL scheme (`rallo://note?text=`).** Shortcuts can open URLs, but there
  are no Siri phrases, no Spotlight actions and no parameter UI.
- **A Date parameter for When.** Siri would parse speech itself, in every
  language it speaks, but with rules that differ from the CLI and the panel
  (a time already gone, "5:30" read as AM). Rejected for one set of rules.

## Testing

- Rust: the normalisation cases in `phrase.rs`.
- Swift: `createReminder` across the bridge (a phrase sets the deadline; an
  unreadable phrase saves nothing); `CaptureService` against a temporary data
  directory (note, reminder, error message, not-yet-attached timeout); the
  Services handler with a private pasteboard.
- Manual, on an installed build (Shortcuts and Services see an installed app
  in `/Applications` or `~/Applications`, not a build folder): both actions in the Shortcuts app, New Rallo Note from
  TextEdit's right-click menu, the failure path, and the two Siri phrases
  (needs the user's voice).

Size: about 150–300 KB (Swift code and the App Intents metadata Xcode
generates).
