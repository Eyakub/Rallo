# Rallo by Razlio

Capture small thoughts and one-time reminders from a fast command; an optional
floating animal keeps them quietly visible. macOS first.

**Status:** pre-release (milestones M0–M4 built; M5 release candidate next).
Ad-hoc signed, not notarized, Apple Silicon, macOS 14+. See
`docs/platform-support.md`.

## Install

From GitHub Releases, no developer tools needed (`docs/distribution.md`):

```sh
gh api repos/Eyakub/Rallo/contents/scripts/install.sh -H 'Accept: application/vnd.github.raw' | bash
rallo note "Try Rallo"
rallo update        # later: install the newest release
```

## Build

Developer prerequisites: Xcode 26+, Rust (rustup), XcodeGen, and optionally
hyperfine for benchmarks.

```sh
scripts/build-macos.sh --install      # Release build → ~/Applications/Rallo.app
~/Applications/Rallo.app/Contents/Helpers/rallo note "Try Rallo"
~/Applications/Rallo.app/Contents/Helpers/rallo show
```

## Test

```sh
cargo test --workspace
(cd apps/macos && xcodegen generate) && \
  xcodebuild -project apps/macos/Rallo.xcodeproj -scheme Rallo -configuration Release \
  -derivedDataPath build/DerivedData test
```

## Documents

- `rallo-macos-build-plan.md` — authoritative specification
- `docs/architecture.md` — what is built and its interfaces
- `docs/cli-contract.md`, `docs/reminder-semantics.md`, `docs/platform-support.md`
- `docs/backup-and-restore.md` — backup kinds and exact restore steps
- `docs/distribution.md` — install, update, uninstall, and making a release
- `docs/release-report.md` — verified Macs, performance, signing, known limitations
- `skills/rallo/SKILL.md` — how agents should use `rallo`
- `docs/decisions/` — decision records with real observations
- `docs/progress.md` — progress log
