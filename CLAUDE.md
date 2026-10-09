# Rallo — repo notes for agents

- Internal notes live in the gitignored `private/` folder (never commit it):
  the spec `private/rallo-macos-build-plan.md` is authoritative; do not edit
  it or `private/claude-start-prompt.md`. Progress:
  `private/docs/progress.md`; manual checks and the release report sit
  beside it.
- Rust is Homebrew `rustup` (keg-only): `export PATH=/opt/homebrew/opt/rustup/bin:$PATH`.
- Build/install app: `scripts/build-macos.sh --install`. Rust tests:
  `cargo test --workspace`. Swift tests: see README.
- Never hand-edit `apps/macos/Rallo/Generated/` or `apps/macos/Rallo.xcodeproj`
  (generated). Edit `crates/rallo-ffi` and `apps/macos/project.yml` instead.
- Tests and manual checks use `RALLO_DATA_DIR`; never the real data directory.
- Pet window level/collection behaviour is fixed by
  `docs/decisions/0002-pet-window-configuration.md`.
- Commits: conventional, author `eyakubsorkar@gmail.com`, no AI attribution.
- UI changes: render and click through them, and screenshot both Dark and
  Light Mode before calling them done.
- Releases: `scripts/release.sh X.Y.Z` (dry run) then `--publish`, only when
  the user says so. Distribution without a Developer ID: `docs/distribution.md`.
- Build products registered with LaunchServices can receive notification
  clicks meant for the installed app: `lsregister -u` scratch builds.
- Build into a `*.noindex` folder (`build/DerivedData.noindex`, or e.g.
  `build/DerivedData-fix.noindex` for a scratch build): Spotlight skips it, so
  it never offers a build copy as "Rallo" in place of the installed one.
- A terminal can't toggle Reduce Motion (`com.apple.universalaccess` is
  TCC-protected), and `sfltool dumpbtm` blocks on an admin prompt.
