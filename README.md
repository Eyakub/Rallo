# Rallo by Razlio

Capture small thoughts and one-time reminders from a fast command; an optional
floating animal keeps them quietly visible. macOS first.

**Status:** pre-release engineering (milestone M0). Not signed for
distribution, not notarized, Apple Silicon only. See
`docs/platform-support.md`.

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
- `docs/decisions/` — decision records with real observations
- `docs/progress.md` — progress log
