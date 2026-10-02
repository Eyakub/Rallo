# Distribution without an Apple Developer ID

Rallo ships as GitHub Releases of an app signed with **Rallo's own
self-signed certificate** (0.7.2 and later; earlier releases were ad-hoc
signed), **not notarized**, for Apple Silicon (macOS 14+). There is no paid
Apple Developer Program account, so there is no Developer ID signature and no
notarization (see "Signing" below). That is fine for
installs made by `rallo update`, `scripts/install.sh`, `gh`, or `curl`:
those downloads are not quarantined, so Gatekeeper never blocks the app.

A zip downloaded **in a browser** is quarantined. macOS then refuses to open
it the first time; allow it once under System Settings → Privacy & Security
→ "Open Anyway", or clear the flag:
`xattr -dr com.apple.quarantine ~/Applications/Rallo.app`.

## Install

The repository is private for now, so downloads go through your GitHub login
(`gh auth login` once):

```sh
gh api repos/Eyakub/Rallo/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash
```

Once the repository is public, no login is needed:

```sh
curl -fsSL https://raw.githubusercontent.com/Eyakub/Rallo/master/scripts/install.sh | bash
```

To read the script before running it, save it to a file first. It installs to
`~/Applications` (no administrator password; `--system` for `/Applications`),
verifies the release's SHA-256 and the app's signature, links the `rallo`
terminal command into `~/.local/bin` (adding that folder to PATH in
`~/.zprofile`, or `~/.bash_profile` for bash, when it isn't on PATH yet;
open a new terminal afterwards), and opens Rallo. `--version X.Y.Z` picks a release;
`--from DIR` installs a zip and `SHA256SUMS` you already downloaded.

## Update

```sh
rallo update --check   # is there a newer release?
rallo update           # install it
```

`rallo update` is the only Rallo command that uses the network, and it runs
only when you type it. The one background use is opt-in: Settings → General
→ "Check for updates daily" (off by default) makes the app run
`rallo update --check` at most once a day. It shows "Update to Rallo X…" in
the menu and posts one notification per version; installing always goes
through Settings → About and its confirmation. Scratch (`--data-dir`)
instances never check. See `docs/decisions/0011-update-check.md`.

Installing downloads the
latest release, verifies the checksum, bundle identifier, version, and
signature, backs up your notes, quits Rallo, swaps the app (restoring the
old one if anything fails), and relaunches it in the background with your
pet shown or hidden as before. Re-running the install script also updates.

What carries over, measured on this Mac across many ad-hoc-signed
reinstalls (with the release certificate, Keychain access and app
permissions carry over too, after one last prompt when coming from an ad-hoc
release): your notes and settings (they live in
`~/Library/Application Support/Razlio/Rallo`, never inside the app), the
terminal command, and notification permission. macOS drops Rallo's pending
notification requests when the app is replaced; the app re-adds future
reminders as soon as it relaunches (`missing_from_readback` in 0005), so a
reminder due in the few seconds of an update can be missed.

## Agents

Any agent that can run local commands can use `rallo`. It needs the
terminal command on PATH for shells that aren't interactive (`rallo
doctor` says when it isn't), and instructions on how to use it:

- **Claude Code and Cursor:** `rallo setup skill` installs the skill as
  `~/.claude/skills/rallo/SKILL.md`. Claude Code picks it up in running
  sessions too (`/skills` lists it); Cursor reads that folder as well.
- **Codex CLI and the Codex tab of the ChatGPT desktop app** (they share
  `~/.codex`, or `$CODEX_HOME`): `rallo setup skill` installs the skill as
  `~/.codex/skills/rallo/SKILL.md` (or `$CODEX_HOME/skills/rallo/SKILL.md`)
  and also writes `rallo.rules`, an execpolicy file that pre-approves
  Rallo's everyday note/reminder commands (`note`, `remind`, `list`, `get`,
  `search`, `done`, `reopen`, `snooze`, `reschedule`, `acknowledge`,
  `cancel-reminder`, `edit`, `delete`, `restore`, `show`, `hide` -- never
  `update`, `setup`, `backup`, `import`, `export`, or `doctor`) so Codex's
  default sandbox doesn't block Rallo's store in `~/Library` with a storage
  permission error. Delete `rallo.rules` to undo it. Plain ChatGPT chat
  (without the Codex tab) can't run local commands, so it can't use Rallo.
- **Anything else:** `rallo setup skill --print` prints the same
  instructions; put them wherever the agent takes standing instructions.

With no `--agent` flag, `rallo setup skill` installs for every agent
detected on this Mac (falling back to Claude Code/Cursor if none is);
`--agent claude`/`--agent codex` (repeatable) installs only those.

The skill ships inside the CLI, so each release carries its own. After an
update, `rallo doctor` warns if an installed copy (skill or Codex's
`rallo.rules`) is older; run `rallo setup skill` again. Claude Code, Cursor
and Codex were tested with it.

`rallo setup hooks` (Claude Code and Codex; not Cursor, which has no hook
mechanism) goes further than the skill: it wires up the `agent-event` hook
command so the pet notices *while an agent is running*, not just when it
reads the skill. It waves when Claude Code or Codex is waiting on a
permission answer, without any network
call or global input monitoring -- `docs/decisions/0007-agent-attention.md`
has the full design. It edits `~/.claude/settings.json` and/or
`$CODEX_HOME/hooks.json` the same carefully-merged way `setup skill` edits
its files (nothing else in either file is touched, and a backup is made
before the first change); `rallo doctor` reports whether it's installed and
pointing at the right copy. Like `setup skill`, it only works from an
installed copy in `/Applications` or `~/Applications`, since the hook
command needs an absolute path. Codex will ask you to trust the new hooks
the next time it starts.

A waiting agent reaches further than the pet
(`docs/decisions/0008-agent-attention-reach.md`): the menu bar's paw carries
the waiting-agent count and a tooltip listing every session, and an "Agents"
section at the top of the menu brings one forward without opening the
panel. An opt-in menu toggle, "Notify When an Agent Waits 5 Minutes" (off by
default), posts one local notification per waiting period once a session
has waited that long, using the same notification permission as reminders.
Two global shortcuts work from any app, without Accessibility or Input
Monitoring permission: ⌃⌥⌘J brings the longest-waiting agent's terminal
forward (press again within 5 s to cycle through the rest), and ⌃⌥⌘N opens
or closes the notes panel.

## Uninstall

```sh
rallo uninstall          # keeps your notes
rallo uninstall --purge  # also deletes them, after a JSON export to ~/Downloads
```

Also available as Settings → About → Uninstall Rallo…. It removes the app, the
`rallo` command, Rallo's agent hooks and skill, Open at Login, scheduled
reminders, the ClickUp token, and voice API keys. `--purge` removes nothing if it can't save
that export first. The PATH line Rallo may have added to your login profile is
left in place (other tools may use `~/.local/bin`).

When the `rallo` command is already gone, the install script does the same
(it runs `rallo uninstall --yes` from the installed app, and falls back to
removing just the app and its terminal command for older versions):

```sh
bash scripts/install.sh --uninstall          # keeps your notes
bash scripts/install.sh --uninstall --purge  # also deletes them, after a JSON export to ~/Downloads
```

## Signing

Releases are signed with "Rallo Self-Signed", a code-signing certificate whose
private key lives only in the maintainer's login Keychain
([decision 0012](decisions/0012-self-signed-release-certificate.md)). macOS
then recognises every release as the same app, so permissions and the
Keychain's "Always Allow" survive updates, and `rallo update` and
`scripts/install.sh` refuse downloads not signed with it (the pin is
`SIGNING_REQUIREMENT` in both). It isn't trusted by Apple, so Gatekeeper
behaves as for an ad-hoc app.

`scripts/build-macos.sh` re-signs the Xcode build when the certificate is in
the Keychain (`RALLO_SIGN_IDENTITY` overrides the name) and leaves it ad-hoc
otherwise; `scripts/release.sh` refuses an ad-hoc build.

Back up the key: Keychain Access → login → My Certificates → "Rallo
Self-Signed" → Export as a password-protected `.p12`, kept somewhere other
than this Mac. Without it, a new certificate means new pins, and existing
installs would have to reinstall with the install script once.

## Making a release (maintainer, on this Mac)

```sh
scripts/set-version.sh 0.2.0 && git commit -am "chore(release): 0.2.0"
scripts/release.sh 0.2.0             # checks, build, package, verify: nothing published
scripts/lifecycle-test.sh build/dist/0.2.0 --upgrade-from <previous release assets>
scripts/release.sh 0.2.0 --publish   # tag v0.2.0, push the tag, create the GitHub release
```

`release.sh` refuses to run off `master`, with uncommitted tracked changes,
with mismatched versions, or for an existing tag. It runs `cargo fmt`,
clippy, the Rust and Swift tests, builds the Release app, and checks the
bundle identifier, versions, the release certificate (and that both pins
match it), and that no binary links anything outside the OS. Assets:

| Asset | Contents |
|---|---|
| `Rallo-<version>-macos-arm64.zip` | `ditto --keepParent` of `Rallo.app` |
| `SHA256SUMS` | `shasum -a 256` of the zip |

Intel Macs are not supported by these builds.
