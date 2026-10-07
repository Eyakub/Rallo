# 0018 — Images on notes

- **Status:** accepted (user, 2026-10-07)
- **Date:** 2026-10-07

## Context

A note is text only (64 KiB, 0003). People want to keep a screenshot with a
note ("this button is broken", "the error looked like this"), and agents
that take screenshots want to save them with the note they write. The notes
panel also shows every note's first line in semibold, so a note typed as one
paragraph renders as a bold block (`NoteParts` in `NoteRow.swift`).

## Decision

### Note rows: a title only when the user wrote one

`NoteParts` splits a title off only on the user's own signal:

- the first line, when the note has a line break after it, or
- the text before the first `": "` (colon then space) on the first line,

and only when that part is 1–60 characters and text follows it. The title
is semibold 14 pt; the body is regular (collapsed: one line, `Theme.bark`;
expanded: full, `Theme.ink`). Otherwise there is no title: the whole note is
regular 14 pt `Theme.ink`, two lines collapsed with an ellipsis, full when
expanded. `5:30pm`, `https://…` and `a:b` never split (no space after the
colon). In the panel's note field, ⇧↩ inserts a line break (⌥↩ still does),
↩ saves, and a hint under the field says "⇧↩ new line".

### Storage

- Images are files under the data directory:
  `attachments/<item id>/<image id>.<ext>` (directories `0700`, files
  `0600`), kept byte-for-byte as received; never converted, resized or
  stripped.
- Schema v5 adds a `STRICT` table:

  ```sql
  CREATE TABLE attachments (
      id            TEXT PRIMARY KEY,
      item_id       TEXT NOT NULL REFERENCES items (id),
      file_name     TEXT NOT NULL,
      mime_type     TEXT NOT NULL CHECK (mime_type IN ('image/png',
                    'image/jpeg', 'image/heic', 'image/gif', 'image/webp')),
      byte_size     INTEGER NOT NULL CHECK (byte_size BETWEEN 1 AND 10485760),
      position      INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX attachments_item ON attachments (item_id, position);
  ```

  The migration only adds; the usual pre-migration snapshot is taken.
- **Write order:** each image is written to a temp file in its item's
  directory, `fsync`ed, and renamed into place; then one transaction inserts
  the item (for a new note) and its `attachments` rows. If the transaction
  fails, the files just written are removed. A crash between the two leaves
  files without rows, which the sweep below removes.
- **Formats** are recognised by their first bytes, never the file name: PNG,
  JPEG, HEIC (`ftyp` `heic`/`heix`/`mif1`), GIF, WebP. Anything else:
  `IMAGE_UNSUPPORTED` ("not an image Rallo can store: use PNG, JPEG, HEIC,
  GIF or WebP"). In the app, an image over 10 MB that Rallo can re-encode is
  saved as HEIC so it fits; the CLI stores files byte-for-byte.
- **Limits:** 10 MiB per image (`IMAGE_TOO_LARGE`), 10 images per note
  (`TOO_MANY_IMAGES`). Over a limit, nothing is saved.
- **A note needs text or at least one image.** The empty-text check
  (`TEXT_EMPTY`, "a note needs text or an image") applies only when there are
  no images; editing an image note's text to empty is allowed, removing the
  last image of a text-less note is refused. A text-less row shows its image
  and "Image" in `Theme.bark`.
- Adding or removing images is a change to the note: `revision`,
  `updated_at_ms` and the change revision move, and `--if-revision` applies.
- **Search** reads note text only; there is no text recognition in images.

### Deleting, the sweep

- Deleting a note keeps its images; restoring within 30 days brings them
  back.
- A sweep runs when the app opens the store and once a day:
  - images of notes deleted more than 30 days ago are removed (rows and
    files). The deleted note itself stays, as today; a note left with no
    text and no images can't be restored (`TEXT_EMPTY`, "nothing left to
    restore: its images were removed 30 days after it was deleted"). Its
    row is kept rather than removed so the reminder and notification
    records tied to it (0005) are never touched;
  - files under `attachments/` with no row, older than one hour, are
    removed (the hour keeps a CLI write in progress from being swept by the
    app).
- Removing one image deletes its row and file at once. The panel's Remove
  Image reads the image into memory first and shows a 5 s Undo toast; Undo
  attaches it again (at the end of the note's images).

### Ways in

1. **Panel.** ⌘V with an image on the clipboard adds it to the note field as
   a thumbnail (× removes it); dropping image files on the field does the
   same; ↩ saves text and images together. Dropping images on a note's row
   adds them to that note (the row highlights while dragging). Clipboard
   images in TIFF (what many apps copy) are converted to PNG in Swift before
   they reach the core; the five stored formats pass through untouched.
2. **CLI.** `rallo note [TEXT] --image PATH` (repeatable, up to 10; TEXT
   optional when there is an image) and `rallo remind TEXT --image PATH …`.
   `rallo attach ID PATH…` adds images to a note; `rallo detach ID IMAGE_ID`
   removes one. Rallo copies the files; an unreadable path is
   `IMAGE_UNREADABLE`. All of these exit 2 and write nothing on refusal
   except `detach` of an unknown image: `IMAGE_NOT_FOUND`, exit 3.
3. **Services.** "New Rallo Note" also accepts images (`NSSendTypes` gains
   `public.png` and `public.tiff`): an image becomes a text-less note; if the
   selection carries text, the text is used, as today. Failure opens the
   panel with the error (0017).
4. **Shortcuts / Spotlight.** Add Rallo Note and Add Rallo Reminder gain an
   optional **Images** parameter (`[IntentFile]`, images only); Note becomes
   optional on Add Rallo Note when images are given.
5. **Screenshot hotkey ⌃⌥⌘S**, off by default (Settings → General,
   "Screenshot to a note"). It runs `/usr/sbin/screencapture -i -x` into a
   temp file (macOS's own region selection; Escape cancels and nothing
   happens), then opens the panel with the capture in the note field and the
   cursor in the text; ↩ saves, Escape discards. Rallo checks Screen
   Recording access first (`CGPreflightScreenCaptureAccess`); without it,
   macOS's prompt is requested once and the panel explains where to allow
   it. The temp file is deleted after saving or discarding.

### Seeing and taking images out

- Collapsed rows show a photo symbol and count in the time line ("now ·
  2 images"); expanded rows show a strip of 56 pt thumbnails (rounded,
  scrolling sideways when they don't fit) above the actions. Thumbnails are
  made off the main thread and cached.
- Click (or Space) opens Quick Look (`QLPreviewPanel`) on the note's images;
  arrow keys move between them.
- A thumbnail drags out as the real file (Slack, Mail, Finder). Its context
  menu: Copy Image, Show in Finder, Remove Image.
- VoiceOver: "Image 1 of 2, PNG"; Quick Look and Remove are reachable by
  keyboard.
- **JSON:** every item in `get`, `list`, `search` and mutation results gains
  `"images": [{"id", "path", "type", "bytes"}]` in position order (`path`
  absolute, `type` the MIME type), `[]` when none. Human output adds "N
  images". The field is an addition, so the JSON contract version
  (`schema_version`) stays 1.
- **Agent skill:** tells agents about `--image` for screenshots they take,
  that `images[].path` can be opened when picking up a note, and that images
  are the user's private data: never upload or send them unless asked.

### Backup, export, import, doctor, uninstall

- `rallo backup` also copies `attachments/` to `<backup>.attachments/`
  (`std::fs::copy`, which clones on APFS, so it costs almost no space until
  files diverge). Pre-migration, pre-import and pre-update snapshots stay
  database-only: image files are never modified after they are written.
  `docs/backup-and-restore.md` gets the restore steps.
- `rallo export --format zip --output PATH` writes `rallo-export.json`
  (export format version 2: version 1 plus `images` per item with `id`,
  `file` = `images/<item id>/<image id>.<ext>`, `type`, `bytes`,
  `created_at_ms`) and the image files, zipped with `/usr/bin/ditto -c -k`
  (no new dependency). The core writes and reads the export as a directory
  (`export_to_dir`, `preview_import_dir`, `apply_import_dir`); zipping and
  unzipping live in `rallo-platform-macos` (`archive`), so the core stays
  free of platform code. JSON and CSV exports leave out image-only notes
  (their text would be empty, which those formats can't import) and say how
  many. `--output -` is refused for zip. JSON and CSV exports
  are unchanged (JSON stays version 1); with images present they warn
  "images aren't included; use --format zip". Settings → Export offers
  "Rallo archive (.zip, with images)".
- `rallo import` detects a zip by its signature. Before extracting, it lists
  the entries (`/usr/bin/zipinfo -1`) and refuses the whole import
  (`INVALID_IMPORT`) if any name is absolute, contains `..`, or is anything
  but `rallo-export.json` and `images/<id>/<id>.<ext>`; after extracting
  into a private temp directory with `ditto -x -k`, every entry must be a
  regular file (no links). Every image is then checked (format, size,
  count) before any write; the import stays all-or-nothing behind its
  pre-import snapshot. Limits: each image ≤ 10 MiB, the JSON ≤ 64 MiB, at most 100 000 entries, and
  enough free space to unpack it (the declared size plus 512 MiB). The
  archive is listed and unpacked under a fixed private name; each unpacked
  file is capped at 64 MiB and unpacking stops when it grows past what the
  archive declares.
- `rallo doctor` adds an `images` check: folder permissions, count and size
  ("38 images, 112 MB"); orphan files are a warning ("Rallo removes them the
  next time it opens"); a row whose file is missing is a problem (fix:
  restore from a backup or `rallo detach`). The data-size line counts
  images.
- `rallo uninstall --purge` saves its final export as the zip in
  `~/Downloads`.

## Alternatives

- **Images as SQLite BLOBs.** One write and existing backups/export would
  cover them, but every pre-update and pre-migration snapshot would copy all
  images, and agents, Quick Look and drag-out would each need a temp file
  written out and cleaned up.
- **Store only the original file's path.** Breaks as soon as the user tidies
  their Desktop.
- **Images base64-encoded in the JSON export.** A single file, but 33 %
  larger, held in memory whole, and far past the 64 MiB import cap.
- **A zip crate.** `ditto` and `zipinfo` ship with macOS; no dependency.
- **Text recognition in images for search.** Apple's Vision could add it
  later; not needed to keep screenshots with notes.

## Testing

- Rust: format detection for each type and refusals (a PNG renamed `.jpg`
  is a PNG; a text file named `.png` is refused); both limits; text-or-image
  rule; write order (a failed transaction removes its files; an orphan file
  older than an hour is swept, a fresh one is not); 30-day sweep at 29 and 31
  days with an injected clock, including a text-less note removed entirely;
  attach/detach revisions; JSON shape; zip export → import round trip;
  zip refusals (`../`, absolute name, unexpected name, a symlink entry,
  oversize image); `doctor` states; `backup` copies the folder.
- CLI integration: `--image`, `attach`, `detach`, exit codes, nothing written
  on refusal.
- Swift: the bridge (create with images, attach, detach); note-field
  staging (paste PNG, paste TIFF → PNG, drop files, remove before saving);
  `NoteParts` (line break, colon, 60-character limit, `5:30pm`, URL);
  Services with an image; Add Rallo Note with Images.
- Manual on an installed build with a throwaway data directory, Dark and
  Light: paste and drop, Quick Look, drag out, Remove with Undo, ⌃⌥⌘S
  including the permission prompt, Services on an image in Preview,
  Shortcuts with an image, zip export/import.

Size: about 300–500 KB of code; no new dependency.
