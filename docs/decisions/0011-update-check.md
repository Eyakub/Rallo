# 0011 — Opt-in daily update check

- **Status:** accepted (user, 2026-10-02). Amends 0010's network rule: Rallo
  also checks for new releases, but only if the user turns it on.
- **Date:** 2026-10-02

## Context

The spec asks for manual updates and no network on the normal CLI path, so
`rallo update` runs only when typed. The result: users had no way to hear
that a release exists.

## Decision

Settings → General has "Check for updates daily", **off by default**. When on,
the app runs its embedded CLI's `rallo update --check --json` (the existing
read-only check) at most once a day: 30 s after launch, then an hourly timer
that skips unless 24 h have passed since the last successful check. A failed
check is retried by the next tick.

When a newer release exists:

- one macOS notification per version (identifier `rallo.update.<version>`);
- "Update to Rallo X…" as the first item of the paw menu;
- the menu item and the notification both open Settings → About and run the
  check there, so the existing "Update Now" button and confirmation dialog do
  the install. Nothing installs without the user confirming.

Turning the setting off clears the stored version and the menu item.
`rallo uninstall --purge` deletes the app's preferences (not under an
explicit or overridden data directory).

## What is sent

One `GET https://api.github.com/repos/Eyakub/Rallo/releases/latest`. The CLI
adds a GitHub token only if `GH_TOKEN` or `GITHUB_TOKEN` is set, or `gh auth
token` provides one (`crates/rallo-platform-macos/src/update.rs`); a launched
app rarely has either. Nothing about the user or their notes is sent.

## Scratch instances

An instance started with a non-default `--data-dir` never checks, and the
toggle is disabled there.

## Not done

- Automatic install.
- Update channels (pre-releases, delayed rollout).
