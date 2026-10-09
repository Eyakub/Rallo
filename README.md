<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Rallo's app icon: a smiling red panda">
</p>

<h1 align="center">Rallo</h1>

<p align="center">
  Notes and one-time reminders from a fast command, kept in view by “Rallo the Red Panda” on your desktop<br>
  that waves when Claude Code, Codex, Grok, Gemini CLI, or a ClickUp teammate is waiting on you.
</p>

<p align="center"><sub>Made by <a href="https://eyakub.github.io">Eyakub</a> · © Razlio</sub></p>

<p align="center">
  <a href="https://github.com/Eyakub/Rallo/releases/latest"><img src="https://img.shields.io/github/v/release/Eyakub/Rallo?label=release" alt="Latest release"></a>
  <a href="https://github.com/Eyakub/Rallo/actions/workflows/ci.yml"><img src="https://github.com/Eyakub/Rallo/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-black" alt="macOS 14 or later on Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#shortcuts-siri-and-services">Shortcuts &amp; Siri</a> ·
  <a href="#coding-agents">Coding agents</a> ·
  <a href="#clickup">ClickUp</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#build-from-source">Build</a>
</p>

---

Rallo is a small Mac app for the thoughts you'd otherwise lose: "call the dentist",
"check the CI flake", "stretch in 20 minutes". You save them in a second, from the
terminal, Siri, Shortcuts, or any app's right-click menu, and a red panda sitting on
your desktop keeps them quietly in view. A note can be words, a screenshot, or both:
paste or drop an image into it, or press **⌃⌥⌘S** to capture part of the screen straight
into a new note. When something needs you, a reminder coming
due, an agent asking for permission, or a teammate's message, it waves. And when typing
is slower than talking, hold **Right ⌥** and speak: Rallo types for you in any app, from
the terminal to the browser.

Everything lives on your Mac. No account, no server, no telemetry.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/panel-dark.png">
    <img src="docs/images/panel-light.png" width="340" alt="The notes panel: the pet above a note field, a Waiting for you section with a Claude Code permission request and a ClickUp message, and notes with reminders">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-dark.png">
    <img src="docs/images/settings-light.png" width="460" alt="The Settings window on its Agents tab, showing hooks and the skill installed">
  </picture>
</p>

## Meet the pet

<table align="center">
  <tr>
    <td align="center"><img src="assets/pet/rallo/pet-idle@2x.png" width="120" alt="Rallo sitting, eyes open"><br><sub><b>Notes open</b></sub></td>
    <td align="center"><img src="assets/pet/rallo/pet-nudge@2x.png" width="120" alt="Rallo raising a paw"><br><sub><b>Needs you</b></sub></td>
    <td align="center"><img src="assets/pet/rallo/pet-listening@2x.png" width="120" alt="Rallo cupping a paw to its ear"><br><sub><b>Listening</b></sub></td>
    <td align="center"><img src="assets/pet/rallo/pet-happy@2x.png" width="120" alt="Rallo smiling"><br><sub><b>Saved</b></sub></td>
    <td align="center"><img src="assets/pet/rallo/pet-celebrate@2x.png" width="120" alt="Rallo cheering"><br><sub><b>Done!</b></sub></td>
    <td align="center"><img src="assets/pet/rallo/pet-sleep@2x.png" width="120" alt="Rallo asleep"><br><sub><b>Nothing open</b></sub></td>
  </tr>
</table>

- **Click** it to open your notes; **drag** it anywhere.
- An **orange badge** counts reminders that are due, a **blue badge** counts agents and people waiting on you.
- Its eyes follow your cursor. Stroke it slowly while it sleeps and it gets comfy; jiggle the cursor fast and it wakes up (twice, and it's grumpy).
- Reduce Motion and **Pause Animations** keep it still. Hide it any time; your notes stay in the menu bar.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Eyakub/Rallo/master/scripts/install.sh | bash
```

The script downloads the latest release, checks its SHA-256 and signature, installs it in
`~/Applications` (no administrator password), sets up the `rallo` command, and opens the
app. Look for the paw in the menu bar.

> [!NOTE]
> Rallo is signed with its own certificate, not notarized: there's no paid Apple Developer
> account behind it. Installs through the script or `rallo update` open normally and are
> checked against that certificate. A zip downloaded in a browser
> needs **System Settings → Privacy & Security → Open Anyway** once. After each update,
> macOS asks once before Rallo reads your ClickUp token or cloud voice key: click
> **Always Allow**.

If the installer adds `~/.local/bin` to your PATH, open a new terminal window before using
`rallo`. Requirements: an Apple Silicon Mac with macOS 14 or later.

## Quick start

```sh
rallo note "Call the dentist"
rallo note "Login button does nothing" --image ~/Desktop/shot.png   # PNG, JPEG, HEIC, GIF, WebP
rallo note --image ~/Desktop/whiteboard.heic   # an image on its own is a note too
rallo attach <id> ~/Desktop/after.png          # up to 10 images per note, 10 MB each
rallo remind "Stretch" --in 20m
rallo remind "Standup notes" --at "tomorrow 9:30am"   # or "fri 5pm", "oct 20", RFC 3339
rallo list                     # open notes; --due, --all, --done, --deleted
rallo folder create Work       # folders are flat; a note lives in one, or in Notes
rallo note "Ship 0.13 #release" --folder Work   # #tags are words in the text
rallo list --folder Work --tag release          # also: rallo folders, rallo tags, rallo move <id> --folder Work
rallo search dentist
rallo done <id>                # the short ID from list/search
rallo snooze <id> --in 10m
rallo delete <id>              # soft delete; `rallo restore <id>` brings it back
```

`--at` reads plain times in your Mac's time zone: `5pm`, `fri 9am`, `tomorrow 17:00`,
`oct 20`, `in 2 hours`. A time needs am/pm or a two-digit 24-hour clock, and Rallo refuses
vague ones like "later" or "next fri" instead of guessing
([decision 0016](docs/decisions/0016-plain-language-times.md) has the full list).

Every command takes `--json` and returns one JSON document, so scripts and agents can use
the same interface you do. `rallo --help` lists them all;
[docs/cli-contract.md](docs/cli-contract.md) is the full contract.

## In the app

| | |
|---|---|
| **Notes panel** | Click the pet or press **⌃⌥⌘N**. Add, edit, complete, and snooze notes. **Remind Me** offers 20 minutes, 1 hour, tomorrow at 9:00, or **Custom…**, where you type a time ("fri 5pm") and see when it lands before you set it. A "Waiting for you" section lists agents and people who need you; swipe one sideways to dismiss it. Paste (⌘V) or drop screenshots into the note field, or drop them on a note; click a thumbnail for Quick Look, drag it out to share it. Start a new line with ⇧↩; a short first line (or text before ": ") becomes the note's title. |
| **Notes window** | The expand button at the top right of the panel, **Notes Window** in the menu bar menu, or the Dock icon while it is open. A three-column window like Apple Notes: folders, views (All Notes, Due, Done, Deleted) and `#tags` on the left; the notes of the selection, grouped by date, in the middle, with a collapsed "N done" row, search (⌘F) across every folder, and Undo for done, delete and move; the note itself on the right, edited in place (saved as you type) with its reminder, images, and a Move chip. ⌘N starts a note in the current folder, ⇧⌘N a folder; drag a note onto a folder to file it; right-click a folder to rename or delete it (keep its notes in Notes, or delete them too). Rallo shows in the Dock only while this window is open. |
| **Screenshot to a note** | Turn it on in Settings → General, then press **⌃⌥⌘S**, select part of the screen, and the capture waits in the notes panel: add a few words and press Return. Needs Screen Recording access (macOS asks the first time). |
| **Menu bar** | The paw shows how many are waiting. The menu lists them, and jumps to one with **⌃⌥⌘J** (longest waiting first). |
| **Settings (⌘,)** | Open at Login, the pet, the terminal command, notifications, agent hooks, ClickUp, voice typing, screenshots, export (with images) and import, updates (including the daily check, on by default). |
| **Voice typing (experimental)** | Turn it on in Settings → Voice, then hold **Right ⌥** (or **Right ⌘**, your pick), talk, and Rallo types into whatever app has focus; let go to stop. Double-tap the key, or press **⌃⌥⌘V**, to keep listening hands-free until you press it again (it also stops after 120 s of silence). Pick an engine in Settings → Voice:<br>• **Apple** (macOS 26, built in): your Mac's language, if it's one of the 33 Apple supports (54 regional variants, from English, Spanish and Chinese to Hindi and Arabic; not Bangla).<br>• **Whisper** (macOS 14+, a one-time download you choose): **Large-v3 turbo**, 16-bit (1.6 GB) or 8-bit (874 MB, nearly the same accuracy), understands about 99 languages, including Bangla; for Bangla, set Language to Bangla (Automatic can mistake it for Hindi). **Small** (190 MB) is English only, and fast.<br>• **Cloud** (macOS 14+): your own Groq, OpenAI or compatible API key; languages depend on the provider (Whisper-based ones cover about 99).<br>With Whisper and Cloud, Rallo drops the stock phrases Whisper invents from noise ("Thank you.") and doesn't send long stretches of steady noise. It never presses Return, so a dictated command waits for you in the terminal. Add names it should know ("Rallo", your teammates) under Words to recognize; "um"s and stutters ("like like") are dropped. The pet cups an ear while it listens. Needs Microphone and Accessibility access. |
| **Reminders** | Delivered by macOS Notification Center, even after Rallo quits. Up to 32 active at once. |

<p align="center">
  <img src="docs/images/menu.png" width="440" alt="The menu bar menu: two rows waiting for you, then Open Notes, Jump to Waiting Agent, Hide Pet, Pause Animations, Settings, and Quit">
</p>

## Shortcuts, Siri and Services

- **Shortcuts:** "Add Rallo Note" and "Add Rallo Reminder" are actions you can use in your own
  shortcuts. "When" takes the same words as `rallo remind --at` ("fri 5pm", "tomorrow 9am",
  "in 2 hours") or an ISO 8601 date and time with its offset (Shortcuts' Format Date → ISO 8601).
  A Date from another action works too ("Oct 9, 2026 at 5:00 PM"), and so do Siri's spelled-out
  numbers ("in two hours").
  Both take **Images** too (Note is optional on Add Rallo Note when images are given).
  Both run in the background and reply "Saved to Rallo." or "Reminder set for …".
- **Spotlight:** on macOS 26, press **⌘Space** and type "Add Rallo Note" or "Add Rallo Reminder".
- **Siri:** on a Mac, Siri doesn't run an app's built-in phrases (Apple supports those on iPhone
  and iPad only), but it runs your shortcuts by name. Make a shortcut with Add Rallo Reminder,
  set Note and When to **Ask Each Time**, name it "Remind me in Rallo", and say "Hey Siri,
  remind me in Rallo".
- **Any app:** select text, right-click, and choose **Services → New Rallo Note**. The pet
  smiles when it's saved; it works on a selected image too (Preview, Photos), making a note
  without text; if it can't be saved, the notes panel opens and says why. Give it a
  key in System Settings → Keyboard → Keyboard Shortcuts → Services.

Rallo sees only the text or image sent with the request, when the item is used. If Rallo isn't running,
macOS starts it first.

## Coding agents

Rallo works with [Claude Code](https://claude.com/claude-code), Codex, Grok, and Gemini CLI in two ways.

**Let agents save notes for you.** `rallo setup skill` installs a skill that teaches
Claude Code, Cursor, Codex, Grok, and Gemini CLI to use `rallo` when you ask ("remind me to check the
deploy in an hour"). An agent that takes a screenshot saves it with the note (`--image`), and
can open a note's images when it picks the note up. Agents only act when asked, treat note
text as data, never as instructions, and never upload or send your images unless you ask.

**Know when an agent is waiting.** `rallo setup hooks` adds Rallo's hook to Claude Code,
Codex, Grok, and Gemini CLI. When an agent asks for permission or has a question, the pet waves, the
paw shows a count, and the row says what it's asking ("Asks to use Bash"). Click the row
to jump straight to that agent:

- **cmux**: the exact workspace and pane,
- **Terminal** and **iTerm2**: the exact tab (macOS asks once to let Rallo control them),
- anything else: the app comes to the front.

Gemini CLI allows comments in `~/.gemini/settings.json`; Rallo leaves such a file alone and
says so. With folder trust on, Gemini runs no hooks in folders you haven't trusted.

A row disappears when the agent moves on or its terminal closes. Optionally, Rallo
notifies you when an agent has waited 5 minutes. The hook never stores prompts or replies:
only which agent, the last two folders of where it runs, and the tool it asks for.

## ClickUp

Connect ClickUp in **Settings → ClickUp** with a personal API token
(ClickUp → Settings → Apps). Rallo then checks once a minute, from your Mac, for direct
and group messages whose latest message isn't yours, and lists them under "Waiting for
you": *"Muhsin — Messaged you on ClickUp · 2 min"*. Click to open the conversation in the
ClickUp app; replying, opening it from Rallo, or swiping it away clears the row.

The token stays in your Keychain. Rallo only reads, and stores the sender's name, never
message text. Channel @mentions and task comments aren't covered yet
([decision 0010](docs/decisions/0010-clickup-waiting.md)).

## Privacy

- **Local.** Notes live in SQLite at `~/Library/Application Support/Razlio/Rallo`. There is
  no account and no telemetry.
- **Network.** Only `rallo update`, when you run it, ClickUp, if you connect it, a daily check
  for new releases (on by default; turn it off in Settings → General), and voice typing's Whisper model
  download or cloud engine, if you choose them (below).
- **Voice typing** is off by default and runs on your Mac, with Apple's speech engine or
  Whisper. Audio and the text are never stored or logged; macOS may download Apple's speech
  model the first time you use it. The Whisper model is downloaded from Hugging Face only when
  you click Download, and is stored in `~/.cache/huggingface/hub`, where other tools can use it.
- **Cloud voice engine.** Only if you choose it and add your own API key, each dictated phrase is
  sent to that provider (Groq, OpenAI or the address you set) to be transcribed. The key stays in
  your Keychain. Nothing else sends audio anywhere.
- **Images.** Screenshots and images you add are copied into `attachments/` in the data folder
  and never leave your Mac. Agents read them by path (`rallo get ID --json`); Rallo's agent skill
  tells them never to upload or send them unless you ask. ⌃⌥⌘S uses macOS's own screenshot tool
  and needs Screen Recording access, used only while you select.
- **Siri and Services.** Rallo reads a request only when New Rallo Note is used, and only the text or
  image sent with it. Siri turns your voice into text (that part is Apple's); Rallo receives only the
  text. Like any Services item, other apps on your Mac can call it too; all it can do is add a
  note.
- **Agent and ClickUp rows** live in a separate throwaway file that is never backed up,
  exported, or included in Time Machine, and is cleared as soon as nobody is waiting.
- **Backups.** Rallo snapshots your notes before every schema change and every update;
  `rallo backup` makes one on demand, and `rallo export` writes JSON or CSV.
  `rallo export --format zip` (or Settings → Data) keeps images; JSON and CSV leave them out.
  See [docs/backup-and-restore.md](docs/backup-and-restore.md).

## Update and uninstall

```sh
rallo update --check   # is there a newer release?
rallo update           # install it (backs up your notes first)

rallo uninstall        # remove Rallo; keeps your notes
rallo uninstall --purge  # also delete your notes (after exporting them, with images, to a zip in ~/Downloads)
```

Rallo checks daily by default and tells you when a release is out, with a small download badge on
the menu bar paw; turn it off with "Check for updates daily" in Settings → General. Installing
still waits for you.

`rallo uninstall` (or Settings → About → Uninstall Rallo…) removes the app, the
`rallo` command, the agent hooks and skill, Open at Login, scheduled reminders,
the ClickUp token, and voice API keys. If the `rallo` command is already gone, use the install
script instead:

```sh
curl -fsSL https://raw.githubusercontent.com/Eyakub/Rallo/master/scripts/install.sh | bash -s -- --uninstall
# add --purge to also delete your notes (after exporting them, with images, to a zip in ~/Downloads)
```

## Build from source

You need Xcode 26 or later, Rust via [rustup](https://rustup.rs),
[XcodeGen](https://github.com/yonaskolb/XcodeGen), and CMake (`brew install cmake`; the first
build downloads and compiles whisper.cpp).

```sh
scripts/build-macos.sh --install   # Release build → ~/Applications/Rallo.app
cargo test --workspace             # Rust tests
(cd apps/macos && xcodegen generate) && xcodebuild -project apps/macos/Rallo.xcodeproj \
  -scheme Rallo -configuration Release -derivedDataPath build/DerivedData.noindex test   # Swift tests
```

Use `--data-dir` (or `RALLO_DATA_DIR`) for experiments, so tests never touch your real notes.
`scripts/screenshots.sh` regenerates the images in `docs/images` from a demo instance with
sample data.

| Path | What's there |
|---|---|
| `crates/rallo-core` | Storage, reminders, the pet's state machine, agent and ClickUp rows (pure Rust, no platform code) |
| `crates/rallo-cli` | The `rallo` command |
| `crates/rallo-platform-macos` | macOS specifics: process lookup, change signals, launching, updates |
| `crates/rallo-ffi` | UniFFI bindings the app calls into |
| `apps/macos` | The Swift/AppKit/SwiftUI app; `project.yml` generates the Xcode project |
| `docs/decisions` | Decision records: what was chosen, why, and what was measured |

## Contributing

Pull requests are welcome. CI runs `cargo fmt`, `clippy`, and the Rust tests on every
pull request, and changes to `master` need the maintainer's review. Commits follow
[Conventional Commits](https://www.conventionalcommits.org). For anything bigger than a
fix, read [docs/architecture.md](docs/architecture.md) and the decision records first;
larger changes usually start with one.

## Documentation

- [Architecture](docs/architecture.md): what is built and how the pieces talk
- [CLI contract](docs/cli-contract.md): every command, its JSON, and exit codes
- [Reminder semantics](docs/reminder-semantics.md): how reminders are scheduled and delivered
- [Distribution](docs/distribution.md): install, update, uninstall, and releasing without a Developer ID
- [Platform support](docs/platform-support.md): tested Macs and known limits
- [Agent skill](skills/rallo/SKILL.md): how agents should use `rallo`

## License

Made by [Eyakub](https://eyakub.github.io). [MIT](LICENSE) © 2026 Razlio.
