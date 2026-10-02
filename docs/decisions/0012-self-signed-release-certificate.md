# 0012 — Sign releases with Rallo's own certificate

- **Status:** accepted (user, 2026-10-02).
- **Date:** 2026-10-02

## Context

Releases were ad-hoc signed. macOS identifies an ad-hoc app by the hash of
that exact build, so every update looked like a different app: the Keychain
asked again for the ClickUp token, and any permission granted to the app
(Accessibility, Microphone) would be lost on each update. Voice typing needs
Accessibility, so this had to be fixed first. A Developer ID would fix it
too, but needs the paid Apple Developer Program.

## Decision

Releases are signed with a self-signed code-signing certificate, "Rallo
Self-Signed", whose private key lives only in the maintainer's login Keychain.

- The app's designated requirement becomes `identifier "com.razlio.rallo" and
  certificate root = H"e380b078…d30e"` instead of a per-build hash, so macOS
  treats every release signed with that key as the same app: permissions
  survive updates. Keychain "Always Allow" only partly does (see below).
- `scripts/build-macos.sh` re-signs Xcode's ad-hoc build (helper first, then
  the app, keeping identifier, entitlements, and the hardened runtime) when
  the certificate is in the Keychain; otherwise the build stays ad-hoc, which
  is fine for development, tests, and contributors.
- Downloads are pinned to that certificate: `rallo update` and
  `scripts/install.sh` (except `--from DIR`, a local copy the user chose)
  require `certificate leaf = H"E380B078…D30E"`. A replaced zip and
  `SHA256SUMS` on GitHub alone can no longer install anything.
- `scripts/release.sh` refuses a build that doesn't satisfy the pin, and
  checks that the pins in `install.sh` and `update.rs` are the same.

## Consequences

- The first update from an ad-hoc release (0.7.1 or earlier) to a signed one
  asks once more for permissions; later updates don't.
- **Correction (0.8.1): the Keychain still asks after every update.** A
  Keychain item's access list trusts the certificate requirement, but its
  partition list (macOS 10.12+) names the caller's Team ID, and an app
  without one is listed by `cdhash:`, i.e. per build. So after each update
  macOS asks once per item Rallo reads (the ClickUp token, a cloud voice key)
  until the user clicks "Always Allow" and enters their login password. Only
  a Developer ID (a Team ID) removes this. Since 0.8.1 Rallo reads each item
  at most once per launch and checks whether a key is saved from its
  attributes, which never prompts.
- Gatekeeper is unchanged: the certificate isn't trusted by Apple and the app
  isn't notarized, so a zip downloaded in a browser still needs "Open Anyway"
  once. Installs through the script or `rallo update` aren't quarantined.
- `install.sh --version` can't install releases before 0.7.2 from GitHub any
  more (they fail the pin); download them and use `--from` instead.
- **The private key must be backed up.** If it's lost, a new certificate
  means new pins, and existing installs' `rallo update` refuses releases
  signed with it: users would have to reinstall with the install script once.
  If it leaks, someone could sign an app that macOS treats as Rallo (including
  access to the ClickUp token): rotate the certificate and pins at once.

## Not done

Notarization and a Developer ID (paid program); signing in CI (releases are
built on the maintainer's Mac, and the key stays there).
