# Rallo — repo notes for agents

- Spec: `rallo-macos-build-plan.md` is authoritative. Do not edit it or
  `claude-start-prompt.md`. Progress: `docs/progress.md`.
- Rust is Homebrew `rustup` (keg-only): `export PATH=/opt/homebrew/opt/rustup/bin:$PATH`.
- Build/install app: `scripts/build-macos.sh --install`. Rust tests:
  `cargo test --workspace`. Swift tests: see README.
- Never hand-edit `apps/macos/Rallo/Generated/` or `apps/macos/Rallo.xcodeproj`
  (generated). Edit `crates/rallo-ffi` and `apps/macos/project.yml` instead.
- Tests and manual checks use `RALLO_DATA_DIR`; never the real data directory.
- Pet window level/collection behaviour is fixed by
  `docs/decisions/0002-pet-window-configuration.md`.
- Commits: conventional, author `eyakubsorkar@gmail.com`, no AI attribution.
