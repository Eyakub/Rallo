# Distribution without an Apple Developer ID

Rallo ships as GitHub Releases of an **ad-hoc-signed, non-notarized** app for
Apple Silicon (macOS 14+). There is no paid Apple Developer Program account,
so there is no Developer ID signature and no notarization. That is fine for
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
terminal command, and opens Rallo. `--version X.Y.Z` picks a release;
`--from DIR` installs a zip and `SHA256SUMS` you already downloaded.

## Update

```sh
rallo update --check   # is there a newer release?
rallo update           # install it
```

`rallo update` is the only Rallo command that uses the network, and it runs
only when you type it: there are no background checks. It downloads the
latest release, verifies the checksum, bundle identifier, version, and
signature, backs up your notes, quits Rallo, swaps the app (restoring the
old one if anything fails), and relaunches it in the background with your
pet shown or hidden as before. Re-running the install script also updates.

What carries over, measured on this Mac across many ad-hoc-signed
reinstalls: your notes and settings (they live in
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
- **Anything else:** `rallo setup skill --print` prints the same
  instructions; put them wherever the agent takes standing instructions.

The skill ships inside the CLI, so each release carries its own. After an
update, `rallo doctor` warns if the installed copy is older; run `rallo
setup skill` again. Tested placements are in `agent-evaluation.md`.

## Uninstall

```sh
bash scripts/install.sh --uninstall          # keeps your notes
bash scripts/install.sh --uninstall --purge  # also deletes them, after a JSON export to ~/Downloads
```

`--purge` removes nothing if it can't save that export first.

Turn off Open at Login from Rallo's menu first if you enabled it (otherwise
remove it under System Settings → General → Login Items).

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
bundle identifier, versions, signature, and that no binary links anything
outside the OS. Assets:

| Asset | Contents |
|---|---|
| `Rallo-<version>-macos-arm64.zip` | `ditto --keepParent` of `Rallo.app` |
| `SHA256SUMS` | `shasum -a 256` of the zip |

Intel Macs are not supported by these builds.
