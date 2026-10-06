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
| **Add Rallo Reminder** | Note; When (text; Siri asks "When?") | in the background | "Reminder set for Fri 9 Oct at 5:00 PM." (`ReminderLabel`); if macOS won't show Rallo's alerts, the reply says so (below) |

- **When** is text read with 0016's rules, exactly as `rallo remind --at`:
  RFC 3339 first, then a phrase. A Shortcuts user with a Date value passes it
  formatted as ISO 8601. A phrase Rallo can't read fails the action with the
  0016 hint, which Siri speaks; nothing is saved.
- The reminder is saved in one write with its note, as `rallo remind` does
  (`Store::create_reminder`, exposed to Swift as `RalloStore.createReminder`).
- App Shortcuts, English: "Add a note in Rallo", "New Rallo note", "Remind me
  in Rallo", "New Rallo reminder". App Shortcut phrases can't carry free text,
  so Siri asks for the note and the time.
- **Amended 2026-10-06 (after 0.10.1):** Siri on macOS does not run App
  Shortcut phrases. Apple DTS: "voice invocation of those intents as App
  Shortcuts isn't available on macOS"
  (developer.apple.com/forums/thread/764609); confirmed on macOS 27, where
  Siri answered "I don't see an app for that". The App Shortcuts still list
  the actions in Spotlight (⌘Space, macOS 26 and later; confirmed working)
  and the Shortcuts app. Siri on a Mac reaches Rallo through a shortcut the
  user makes and names (e.g. "Remind me in Rallo" with Note and When set to
  Ask Each Time), which Siri runs by name; the README says how. Rallo is
  self-signed with no Team ID, so linkd logs "Unable to get teamId" while
  indexing; that did not stop Spotlight from listing or running the
  actions.
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
"Tomorrow at 9 a.m." and "fri 5pm." now resolve.

Amended 2026-10-06 (after 0.10.0), for text Siri and Shortcuts produce:

- A comma anywhere is a separator, read as a space, so a Shortcuts Date
  dropped into When as text ("Oct 9, 2026 at 5:00 PM", with the narrow
  no-break space macOS puts before PM) and "fri, 5pm" resolve. A weekday
  together with a date ("Friday, October 9") is still refused: at most one
  day-or-date.
- Number words become digits: `one` to `nineteen`, the tens `twenty` to
  `ninety`, and a ten plus a unit written with a space or a hyphen
  (`forty five`, `forty-five`). `a`/`an` right after `in` is 1, and
  `half an hour` is 30 minutes: "in two hours", "in an hour", "in half an
  hour", "tomorrow at nine am" resolve. A bare number word is still a bare
  hour ("nine" alone is refused, as "9" is), and "nine thirty" is not
  "9:30".

Everything else in 0016 is unchanged; other punctuation and emoji are still
refused, and error messages quote what was typed.

### Reminder reply when alerts are blocked

The core's last-observed notification authorization (0005) decides the
reply, worded as the panel's banner: `denied` → "Reminder set for <label>,
but it won't alert you: notifications for Rallo are off in System
Settings."; `notDetermined` → "Reminder set for <label>, but it won't alert
you until you allow Rallo's notifications."; `authorized`, `provisional`, or
unknown → "Reminder set for <label>." The reminder is saved either way.

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
  TextEdit's right-click menu, the failure path, Add Rallo Note from
  Spotlight, and a user-named shortcut run by Siri (needs the user's voice).

Size: about 150–300 KB (Swift code and the App Intents metadata Xcode
generates).
