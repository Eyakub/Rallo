# 0024 — Automatic backup to iCloud Drive, Google Drive or a folder

- **Status:** accepted (user, 2026-10-21: "an option where they want to keep their backup, either
  Google Drive or Apple cloud"; "only two is enough, after backup olds will be removed"; Google
  through its API, since most people don't install Google Drive for desktop)
- **Amended 2026-11-25 (user):** ship iCloud Drive and Folder… first. A build without a Google
  client ID hides Google Drive instead of showing it as not set up (§4).
- **Date:** 2026-10-21
- **Related:** 0004 (export/import formats), 0012 (self-signed releases, Keychain prompts),
  0010 (ClickUp: Keychain token, `--data-dir` instances), 0018 (images), `docs/backup-and-restore.md`

## Context

Everything lives on one Mac. `rallo backup` (CLI) and Settings → Data → Export make copies by
hand; nothing copies the notes off the Mac on its own. The user wants a backup that lands in the
person's own cloud. Not a Rallo account, not a Rallo server, and not sync: restoring on another
Mac is enough.

## Decision

### 1. One destination, off by default

Settings → Data → **Back up to**: Off · iCloud Drive · Google Drive · Folder….

- **iCloud Drive** writes to `~/Library/Mobile Documents/com~apple~CloudDocs/Rallo Backups/`.
  Rallo isn't sandboxed, so this is a plain file write: no iCloud entitlement, no Apple Team ID.
  Offered only when that folder exists (iCloud Drive is on).
- **Folder…** writes into a folder the user picks, for Dropbox, a NAS or Google Drive for desktop.
- **Google Drive** uploads to a "Rallo Backups" folder in the user's My Drive through Google's
  API (§4).

### 2. What a backup is

The existing zip export (0004: `rallo-export.json` plus `images/`): every item, live and deleted,
folders included, written atomically. Its name is `Rallo Backup <Mac name> <yyyy-MM-dd HH.mm>.zip`,
so several Macs backing up to one place never overwrite each other. Restore is the existing
**Import…** on any Mac. Import refuses a file that conflicts with notes already there (0004), so a
restore is meant for a new or emptied Mac.

### 3. When

- At most once a day, and only when `change_revision` moved since the last successful backup.
- Rallo checks shortly after launch, then hourly (the timer also catches up after sleep).
- A failure is retried at the next hourly check.
- **Back Up Now** ignores both conditions.
- Status line: "Last backup: today at 09:10", "Backing up…", or "Couldn't back up: <reason>. Rallo
  tries again within the hour."

### 4. Google Drive

- **Connect Google Drive…** runs the OAuth flow for installed apps:
  - the browser opens Google's consent page, with PKCE (S256), `access_type=offline` and the
    `drive.file` scope only ("see, create and delete only the files Rallo creates");
  - Google redirects to a one-shot listener on `http://127.0.0.1:<random port>`;
  - Rallo swaps the code for tokens, and stores the refresh token in the Keychain
    (`KeychainSecret`, like the ClickUp token);
  - the status shows the account's email address, from the Drive `about` endpoint.
  No custom URL scheme: Google's desktop clients redirect to loopback.
- **Upload:** creates "Rallo Backups" once (recreated if the user deletes it), then uploads each
  backup with a resumable upload.
- **Errors:** a 401 refreshes the token once. A refresh that fails with `invalid_grant` shows
  "Reconnect Google Drive". A full Drive says so.
- **Disconnect** revokes the token and deletes it from the Keychain.
- **Client ID:** the OAuth client (type "Desktop app") comes from the project owner's Google Cloud
  project. Its ID and secret are build settings read from the gitignored
  `private/google-oauth.env`; they are not secret in an installed app, but they stay out of the
  repo. A build without them doesn't offer Google Drive (amended 2026-11-25; it was shown as
  "Not set up in this build").
- **Consent screen:** it needs a privacy policy URL, so the policy is `docs/privacy.md`. The
  project is published to production: in testing mode Google expires refresh tokens after 7 days.

### 5. Keep the two newest

After a backup is confirmed written or uploaded, Rallo deletes this Mac's older backups beyond
the newest two:
- It deletes only files it wrote itself: it remembers the names (local) or file IDs (Drive) of
  this Mac's backups, never by matching a name pattern.
- A file the user already removed is skipped.
- Another Mac's backups are never touched.

### 6. Scratch instances

An instance started with `--data-dir` (tests, demos) keeps its backup settings in its own defaults
(`PanelDefaults.defaults(forDataDir:)`). It never uses iCloud Drive or Google Drive, and never
reads the Google token; only Folder… works there.

## Not now

Sync between Macs, an in-app restore list or download from Drive, encrypted backups, more than
one destination at a time, a backup history longer than two.
