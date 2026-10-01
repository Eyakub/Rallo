# Rallo by Razlio

Capture small thoughts and one-time reminders from a fast command; an optional
floating animal keeps them quietly visible. macOS first.

**Status:** pre-release. Ad-hoc signed, not notarized, Apple Silicon,
macOS 14+. See `docs/platform-support.md`.

## Install

From GitHub Releases, no developer tools needed (`docs/distribution.md`):

```sh
curl -fsSL https://raw.githubusercontent.com/Eyakub/Rallo/master/scripts/install.sh | bash
rallo note "Try Rallo"
rallo setup skill   # teach Claude Code, Cursor and Codex to use rallo
rallo setup hooks   # optional: the pet waves when an agent waits for you
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

- `docs/architecture.md` — what is built and its interfaces
- `docs/cli-contract.md`, `docs/reminder-semantics.md`, `docs/platform-support.md`
- `docs/backup-and-restore.md` — backup kinds and exact restore steps
- `docs/distribution.md` — install, update, uninstall, and making a release
- `skills/rallo/SKILL.md` — how agents should use `rallo`
- `docs/decisions/` — decision records with real observations

## License

MIT — see `LICENSE`.
