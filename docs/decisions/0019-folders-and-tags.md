# 0019 — Folders and tags

- **Status:** proposed (design agreed with the user in chat, 2026-10-08; this
  written spec awaits the user's review)
- **Date:** 2026-10-08
- **Mockup:** `docs/mockups/folders.html` (open it in a browser; Light and
  Dark switch top right)

## Context

Notes are flat (`items`, schema v5): text, open/done, a reminder, images,
soft delete. As notes pile up, people want them grouped, the way Apple Notes
does: a note lives in one folder, `#tags` cut across folders, and a big
three-column window shows it all. Rallo's notes panel is a 360×460 floating
`NSPanel`, too narrow for a sidebar, so it plays the part of Apple's Quick
Note and a new window plays the part of the Notes app.

Agents write notes through the CLI, so folders and tags are first-class
there too: an agent can file a note into a project's folder.

## Decision

### 1. Model

- **Folders are flat** (no subfolders). A note is in **at most one** folder.
- A note with no folder is in **Notes**, the built-in folder. Notes is not a
  row in the database (`items.folder_id IS NULL`), so it can't be renamed or
  deleted, and the name "Notes" is reserved.
- **Tags** are `#words` in the note's own text. Nothing is stored for them;
  they are found when notes are read (§7).
- **Counts** shown anywhere (chip menu, sidebar, `rallo folders`,
  `rallo tags`) are **open, nondeleted** notes, matching the panel's
  "5 open notes" — except the window's Done, Due and Deleted views, which
  count what they list.

### 2. Schema v6 (`0006_folders.sql`)

```sql
-- 0006: folders (0019). Notes with no folder are in the built-in "Notes".
CREATE TABLE folders (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    name_key      TEXT NOT NULL UNIQUE,  -- trim + NFC + case fold (0003 §6)
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    revision      INTEGER NOT NULL CHECK (revision >= 1)
) STRICT;

ALTER TABLE items ADD COLUMN folder_id TEXT REFERENCES folders (id);

CREATE INDEX items_open_by_folder ON items (folder_id, created_at_ms, id)
    WHERE deleted_at_ms IS NULL AND status = 'open';
```

- Folder IDs are UUIDs like item IDs. `foreign_keys` is already on
  (`storage/database.rs`), so a folder row can only be deleted after its
  notes' `folder_id` is cleared (§5).
- Every folder change and every move bumps `change_revision`, so the app
  reloads as it does for any other change.
- Migration test: a v5 database with notes, reminders and images migrates
  to v6 with every note in Notes and nothing else changed.

### 3. Folder names

- Trimmed; 1–50 characters (`chars().count()` after trim); no control
  characters or line breaks (including U+2028/U+2029) → else `FOLDER_NAME_INVALID` (exit 2).
- `name_key` is the same normalization as an item's `match_key`
  (trim, NFC, case fold). Two folders can't share a key → `FOLDER_EXISTS`
  (exit 4). A key equal to `notes` is reserved → `FOLDER_NAME_INVALID`.
- Renaming to a name with the same key as the folder's own (`work` →
  `Work`) is allowed: it only changes `name`.
- Folders are listed alphabetically by `name_key` (byte order of the
  normalized key, so `école` sorts after `work`; `ponytail:` locale-aware
  order if anyone asks), with Notes always first.
- `folder rename Notes …` and `folder delete Notes` → `FOLDER_NAME_INVALID`.
- The CLI names a folder by **name** (matched on `name_key`, so case doesn't
  matter); `Notes` means "no folder". The FFI uses folder **IDs**.
  Unknown name → `FOLDER_NOT_FOUND` (exit 3); its message lists the
  existing folder names. A folder is **never** created implicitly: a typo in
  `--folder` must not make a junk folder.

### 4. New error codes

| Code | Exit | FFI `RalloError` | When |
|---|---|---|---|
| `FOLDER_NAME_INVALID` | 2 | `InvalidInput` | empty, too long, control characters, or "Notes" |
| `FOLDER_NOT_FOUND` | 3 | `NotFound` | no folder with that name (CLI) or ID (FFI) |
| `FOLDER_EXISTS` | 4 | `Conflict` | another folder already has that name |
| `FOLDER_NOT_EMPTY` | 2 | `Conflict` | `folder delete` on a folder holding notes without `--keep-notes` or `--delete-notes` (CLI only: the FFI always passes a choice) |

### 5. Operations

All folder mutations and `move` follow 0003: a `BEGIN IMMEDIATE`
transaction, `--request-id` receipts (§7 of 0003; command kinds
`folder_create`, `folder_rename`, `folder_delete`, `move`), and no-ops that
succeed with `changed: false`.

- **Create** `folder create NAME` → the new folder.
- **Rename** `folder rename NAME NEW_NAME` → the folder; same name is a
  no-op; bumps the folder's `revision` and `updated_at_ms`.
- **Move** `move ID --folder NAME [--if-revision N]` — an ID-based item
  mutation (0003 §9 order: receipt → resolve → no-op if already there →
  revision check → mutate). Bumps the item's `revision` and `updated_at_ms`.
  A deleted note → `ITEM_DELETED`. Done notes can be moved.
- **Delete** `folder delete NAME [--keep-notes | --delete-notes]`:
  - The folder "holds notes" when any **nondeleted** item has its
    `folder_id`. Then exactly one of the two flags is required, else
    `FOLDER_NOT_EMPTY`, whose message gives the count
    (`Folder “Work” holds 5 notes: pass --keep-notes or --delete-notes`).
    clap rejects both flags together (exit 2). An empty folder needs
    neither.
  - `--keep-notes`: every item in the folder (open, done, and already
    deleted) gets `folder_id = NULL`, `revision + 1`, `updated_at_ms = now`.
    They show up in Notes.
  - `--delete-notes`: every nondeleted item in the folder is soft-deleted
    **through the existing single-item delete path** (so an active reminder
    is disabled and its cancellation intent is queued exactly as
    `rallo delete` does); then every item in the folder, deleted ones
    included, gets `folder_id = NULL`. Restoring such a note puts it in
    Notes.
  - Then the folder row is deleted. All of it is one transaction with one
    `change_revision` bump.
  - Result: `{folder, notes: "kept" | "deleted" | "none", moved, deleted}`.
    The counts are of notes that were **nondeleted**; `notes` is `"none"`
    when the folder held none. Under `--delete-notes` a note's revision goes
    up by 2 (the delete, then the folder clear).
  - `FOLDER_NOT_EMPTY` is a `Conflict` in the core; the CLI maps that one
    code to exit 2.
- **Restore** is unchanged: a note keeps its `folder_id` while deleted, so
  restoring returns it to its folder (or to Notes if that folder was
  deleted in the meantime).
- **Create note**: `note`/`remind` gain `--folder NAME`.

### 6. Listing and search

- `list` gains `--folder NAME`, `--tag TAG`, and a new `--done` filter
  (done, nondeleted, newest completion first: `ORDER BY completed_at_ms
  DESC, id DESC`). `--done` joins `--all`/`--deleted`/`--due` as mutually
  exclusive filters; `--folder` and `--tag` combine with any filter and with
  each other (AND).
- `search TEXT` gains `--folder NAME`.
- `folders` → `{"folders": [{"id": null, "name": "Notes", "open_count"},
  {"id", "name", "open_count"}, ...]}` (Notes first, then alphabetical).
- `tags` → `{"tags": [{"name", "open_count"}, ...]}`, most used first, then
  alphabetical; tags found only in done or deleted notes are left out.
- Item JSON gains `"folder": {"id", "name"} | null` and `"tags": [...]`
  (keys of the tags in the text, first-appearance order, no duplicates).
  This is additive: the JSON contract version stays `1`.
- `total_count` and cursors keep working with `--folder`/`--tag`: both are
  SQL `WHERE` clauses, not post-filters.

### 7. Tags

- **Grammar.** A tag is `#` followed by a letter, then any of letters,
  combining marks, digits, `-`, `_`, and the zero-width joiners U+200C/U+200D,
  where the `#` is at the start of the text or right after whitespace:
  `(?:^|\s)#(\p{L}[\p{L}\p{M}\p{N}_\u{200C}\u{200D}-]*)`. Combining marks
  and joiners matter: `#কাজ` contains a vowel sign, and Bangla conjuncts such
  as `#র‍্যালো` contain a ZWJ. A trailing `-` or `_` is dropped (`#bug-` → `bug`).
- So `#bug`, `#meeting-notes`, `#Q4_plan`, `#কাজ` are tags; `fix #123`,
  `C#`, `# Heading`, `a#b`, and `https://x.y/#frag` are not.
- **Key.** A tag's key is its text NFC-normalized, then lowercased
  (`to_lowercase`), so decomposed and precomposed spellings are one tag; `#Bug` and
  `#bug` are the same tag and are shown as `bug`. `--tag` accepts the tag
  with or without the leading `#`; anything that isn't one valid tag →
  `INVALID_INPUT`.
- **Code.** One parser in `rallo-core` (`items/tags.rs`): `tags(text) ->
  Vec<String>` (keys) and `tag_ranges(text) -> Vec<(utf16_start,
  utf16_len, key)>` for highlighting. A range covers the `#` and the tag
  as written (without a dropped trailing `-`/`_`), in UTF-16 offsets of the
  string passed in; callers pass exactly the string they display. The
  parser is registered on every connection
  as a deterministic SQLite scalar function `rallo_has_tag(text, key)` so
  `--tag` is a `WHERE` clause. The app gets the ranges through the FFI, so
  Swift never re-implements the grammar.
- `ponytail:` tag counts and `--tag` scan every live note's text; fine to
  tens of thousands of notes. Add a cached tag index if it ever shows up in
  a profile.
- Out of scope: renaming a tag (it's text in each note), a tag browser
  beyond the sidebar list.

### 8. Export and import

- Export writes **version 3** for both the plain JSON and the zip's
  `rallo-export.json` (today 1 and 2). v3 adds a top-level
  `"folders": [{"id", "name", "created_at_ms", "updated_at_ms"}]` and a
  `"folder_id"` (string or null) on each item. Whether images are present is
  decided as it is today; the plan must check how the importer uses the
  version number and keep v1 and v2 files importing unchanged (every note to
  Notes).
- **Import, folders first**, inside the import transaction:
  1. same `id` exists → use it (a different name is kept as the existing
     one, with a warning naming both);
  2. else same `name_key` exists → map the imported id to the existing
     folder;
  3. else create it with the imported id and name.
  Then each item's `folder_id` is mapped and compared like its text: an
  existing item that differs only by folder is a **conflict** (0004's
  rules: any conflict aborts the whole import).
- The importer reads `folders`/`folder_id` only when `version >= 3`. For
  v1/v2 files (and CSVs without a `folder` column) a new note goes to
  Notes and an existing note's folder is **not** compared, so old files
  never conflict. 0004 gets a pointer to this section.
- **CSV** gains a trailing `folder` column (the name; empty for Notes),
  with 0004's formula-injection guard applied like `text`. CSV
  import creates a missing folder by name (CSV has no folder ids). The
  header stays case-insensitive, so older CSVs without the column import to
  Notes.
- `--dry-run` reports `new_folders` alongside the item counts.

### 9. FFI (`rallo-ffi`)

New records and enums:

```rust
pub struct FolderSnapshot { pub id: String, pub name: String, pub open_count: u32, pub note_count: u32, pub revision: i64 }
// note_count: open + done, nondeleted (the delete sheet's "It holds N notes")
pub struct FolderOverview {
    pub all_open: u32, pub unfiled_open: u32, pub due: u32, pub done: u32, pub deleted: u32,
    pub folders: Vec<FolderSnapshot>,          // alphabetical
}
pub struct TagSnapshot { pub name: String, pub open_count: u32 }
pub struct TagRange { pub utf16_start: u32, pub utf16_len: u32, pub name: String }
pub enum FolderScope { All, Unfiled, Folder { id: String } }
pub enum ItemListKind { Open, Done, Due, Deleted }
pub struct FolderDeleteResult { pub moved: u32, pub deleted: u32 }
pub struct ItemPage { pub items: Vec<ItemSnapshot>, pub next_cursor: Option<String>, pub total_count: u32 }
```

`ItemSnapshot` gains `folder_id: Option<String>`, `folder_name:
Option<String>`, `tags: Vec<String>`.

New `RalloStore` methods (the uniffi object; Swift sees `RalloStore`):

```rust
fn folder_overview(&self) -> Result<FolderOverview, RalloError>;
fn list_tags(&self) -> Result<Vec<TagSnapshot>, RalloError>;
fn create_folder(&self, name: String) -> Result<FolderSnapshot, RalloError>;
fn rename_folder(&self, id: String, name: String) -> Result<FolderSnapshot, RalloError>;
fn delete_folder(&self, id: String, keep_notes: bool) -> Result<FolderDeleteResult, RalloError>;
fn move_item(&self, id: String, folder_id: Option<String>, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError>;
fn list_items(&self, kind: ItemListKind, scope: FolderScope, tag: Option<String>, limit: u32, cursor: Option<String>) -> Result<ItemPage, RalloError>;
fn search_items(&self, query: String, limit: u32, cursor: Option<String>) -> Result<ItemPage, RalloError>;
fn cancel_reminder(&self, id: String, if_revision: Option<i64>) -> Result<ItemSnapshot, RalloError>;
```

and a free function `fn tag_ranges(text: String) -> Vec<TagRange>`.
`list_items`/`search_items` page with the core's existing opaque cursors
(0003 §10; `limit` 1–200); the panel reads the first page only, the window
loads the next page when its last row appears. `cancel_reminder` is the
CLI's `cancel-reminder` (state `cancelled`), for the editor's Cancel
Reminder.
`create_note_with_images` and `create_reminder_with_images` gain a last
parameter `folder_id: Option<String>`; `create_note`/`create_reminder` (used
by Services and Shortcuts) are unchanged and file into Notes.
`list_open_items` stays. Swift never edits `Generated/`; regenerate with the
existing build script.

### 10. Panel (release 2)

Mockup section 1, options B and C.

- **Folder chip** under the "Notes" title, replacing the subtitle line:
  `[folder icon] Work ⌄  5 open notes`. On All Notes it reads
  `[tray icon] All Notes ⌄  24 open notes`.
- The chip's menu: All Notes (count) — separator — Notes (count), then each
  folder alphabetically (count) — separator — New Folder…. The current
  choice has a checkmark. It is a dropdown drawn inside the panel
  (`FolderScopeMenu`, 214 pt wide, anchored under the chip), not a system
  menu, so it never crosses the panel's edge: a folder icon per row, the
  name truncated with its full text as a tooltip, the count right-aligned,
  soft rust highlight (`Theme.selection`), arrow keys/Return/Esc. New Folder… asks for a
  name (the in-panel dialog below), creates the folder and switches to it;
  a name error is shown under the field and the dialog stays up.
- **Scope**: the list shows the chosen folder's open notes (`list_items(.open,
  scope, nil, …)`), the subtitle counts them, and the note field's
  placeholder is `Add to Work…` (`Add to Notes…` for Notes). On All Notes the
  list and placeholder are today's, and new notes go to Notes. The count
  line reads `N open notes`, or `No open notes` at zero (today's longer
  empty wording doesn't fit beside the chip and the pet); the chip is at
  most 110 pt wide and truncates a long folder name.
- Panel subtitle and chip counts come from `folder_overview` (not the
  length of the listed page, which is capped).
- The choice is a Swift `enum NotesScope: Hashable { case all, unfiled,
  folder(String) }` (`Notes/NotesScope.swift`), remembered in UserDefaults
  `notesPanelScope` as `"all"`, `"unfiled"`, or the folder id (scratch builds
  use their own defaults suite so they never overwrite the installed app's
  choice). An id that no longer exists (deleted, maybe
  by the CLI) falls back to All Notes on the next reload.
- **Row folder label**: on All Notes each row's meta line ends with
  `· [folder icon] Name` (Notes included). Not shown inside a folder.
- **Move to** in the row's context menu, after Remind Me: Notes, then
  folders alphabetically (the note's current one checked and disabled) —
  separator — New Folder… (creates and moves). This menu is a reusable view
  that the window uses too:

  ```swift
  struct FolderMoveMenu: View {
      let currentFolderID: String?        // nil = Notes
      let folders: [FolderSnapshot]       // alphabetical
      let onMove: (String?) -> Void       // nil = Notes
      let onNewFolder: () -> Void
  }
  ```

  New Folder… everywhere uses one helper, `@MainActor final class
  FolderNamePrompter: ObservableObject` with `ask(title: String, initial:
  String, confirmTitle: String, validate: (String) async throws -> Void)
  async -> String?`, shown by `FolderNameOverlay`: a card on a blurred,
  dimmed backdrop inside the panel or window (not an `NSAlert`: `runModal`
  inside a main-actor job starves the `validate` task). `validate` is the
  real create/rename call, so the core's own error message shows under the
  field, and the card stays up until it succeeds or is cancelled.
  Swift never re-implements the name rules (§3). After a move the toast
  says `Moved to Work` with **Undo** (moves it back); inside a folder scope
  the row leaves the list.
- **Tags** in row text are tinted `Theme.rust` and semibold, using
  `tag_ranges`.
- Unchanged: the shortcut and pet click toggle the panel; the agents
  ("Waiting for you") section stays in the panel only.

### 11. Notes window (release 3)

Mockup section 2. The window's sidebar selection is
`enum NotesWindowSelection: Hashable { case scope(NotesScope), due, done,
deleted, tag(String) }`.

- **Window**: `NotesWindowController`, an `NSWindow` (titled, closable,
  miniaturizable, resizable, full-size content view, unified toolbar),
  `isReleasedWhenClosed = false`, min 900×560, first open 1140×690 centred,
  frame autosaved as `RalloNotesWindow`. Content: SwiftUI
  `NavigationSplitView` with three columns (sidebar ~220, list ~330, editor).
  List and editor use the panel's surface gradient; the sidebar uses the
  system sidebar material; `.tint(Theme.rust)`.
- **Expand button** (added to the panel in this release, since it opens
  the window): top right of the panel's title bar, SF Symbol
  `arrow.up.left.and.arrow.down.right`, help and accessibility label
  "Open Notes Window". It closes the panel and opens the window on the
  panel's scope, selecting the panel's expanded row if there is one.
- **Opening**: the panel's expand button; a new status-menu item
  "Notes Window" under "Notes"; clicking the Dock icon while it's open.
  On open: `NSApp.setActivationPolicy(.regular)`, activate, make key. On
  close: back to `.accessory`. The main menu (Rallo, Edit) already exists.
  The shortcut and pet click keep toggling the panel; panel and window may
  be open together and both reload on every change.
- **Menus**: the main menu gains File (New Note ⌘N, New Folder ⇧⌘N,
  Close ⌘W; New items enabled only while the window is key) and Window
  (Minimize ⌘M, Notes Window), and the Rallo menu gets Quit ⌘Q if it lacks
  it. ⌘Z stays with the text view; the Undo toast is click-only.
- **Quit**: `applicationShouldTerminate` flushes the editor's pending save
  first.
- **Sidebar**:
  - **Folders** (header with a + button): Notes, then folders
    alphabetically, each with its open count. A folder's context menu:
    Rename (inline), Delete Folder… (§12). The footer has
    "+ New Folder" (⌘⇧N): creates "New Folder" (or "New Folder 2", …) and
    starts an inline rename.
  - **Views**: All Notes (open count), Due (due count), Done (done count),
    Deleted (deleted count).
  - **Tags** (hidden when there are none): `# name` and open count; selecting
    one lists open notes with that tag across all folders.
  - Each folder (and Notes) is a drop target for notes dragged from the list
    (drag payload: the item id as a string; an unknown id is ignored).
- **List**:
  - Header: the scope's name (`Work`, `All Notes`, `#bug`, …) and a
    subtitle (`5 open · 2 done` for folders, Notes, All Notes and tags; the
    count for Due/Done/Deleted).
  - Open notes, newest first, grouped by creation date: Today, Yesterday,
    Previous 7 Days, Previous 30 Days, then month names (`September`, or
    `August 2025` outside the current year). Due is sorted by deadline
    without groups; Done is grouped by completion date; Deleted by deletion
    date.
  - Row: completion circle (toggles done), title (the `NoteParts` title, or
    the first line), then one line with the time (today `10:42`, this week
    the weekday, else the date) or the reminder (bell, `Theme.rust`)
    followed by the body preview; the first image as a 38 pt thumbnail on
    the right. Selection everywhere is the soft rust wash (`Theme.selection`
    focused, `selectionSoft` unfocused) with ink text and a semibold sidebar
    label; never system blue, and the app accent is rust. The sidebar's ↑/↓
    moves the selection.
  - Done notes of the scope sit in a collapsed `N done` row at the bottom;
    expanding it shows them dimmed.
  - Deleted view rows offer Restore (context menu and toolbar), no delete.
  - Toolbar: Delete (trash, also ⌫ in the list) and New Note (compose, ⌘N;
    disabled in Due, Done, Deleted and search results). Delete, done and
    move show the same Undo toast as the panel, at the bottom of the list.
  - **Search** (toolbar field, ⌘F): while it has text, the list shows
    `search_items` results across all folders (open and done) under the
    header "Results"; clearing it returns to the scope.
- **Editor**:
  - Empty state: "No note selected" in `Theme.bark`.
  - Toolbar: Mark as Done / Reopen, Remind Me (the same menu as a panel
    row), Add Image (`NSOpenPanel`, images only, then `attach_images`),
    the Move chip (`[folder] Work ⌄` → `FolderMoveMenu`), then the search
    field on the right.
  - Body: created date centred (`8 October 2026 at 10:42`); the reminder
    pill (bell, `Theme.rust`; click: the Remind Me menu, plus Cancel
    Reminder); the text in an `NSTextView` (plain text only; paste drops
    formatting): the `NoteParts` title, when there is one, in 24 pt semibold
    rounded, the rest 14.5 pt, `#tags` in `Theme.rust` semibold via
    `tag_ranges`; images below as 210×140 tiles with Quick Look, drag-out and
    remove, as in the panel (`ImageStrip`, sized up).
  - **Saving**: 0.6 s after typing stops, and when the selection changes or
    the window closes, through `edit_item_text(id, text, revision)`.
    `REVISION_CONFLICT` (an agent or the CLI changed it meanwhile) shows a
    bar at the top of the editor: "This note changed somewhere else."
    [Show Theirs] [Keep Mine] (Keep Mine saves again on the new revision).
    An emptied note with no images isn't saved; leaving it puts the saved
    text back. `TEXT_TOO_LONG` shows inline and keeps the editor's text.
  - **New note** (⌘N): a "New Note" draft row at the top of the list,
    selected, editor focused. The first non-empty save creates it with
    `create_note_with_images(text, [], folder)`, where folder is the scope's
    folder (nil for Notes, All Notes and tags; in a tag scope the text
    starts as `#tag `). Leaving it empty discards it.
- **Live reload**: on the change signal the window reloads overview, tags
  and list, keeping the selection; a selected note that's gone (deleted
  elsewhere) clears the selection, and a deleted scope folder switches to
  Notes. An editor with unsaved typing is not overwritten by a reload; the
  conflict bar handles it on save.

### 12. Deleting a folder in the app

From the sidebar (window only). A sheet:

- Folder with notes (`note_count > 0`): **Delete “Work”?** — "It holds 5 notes. Keep them in
  Notes, or delete them too? Deleted notes stay in Deleted, where you can
  restore them." Buttons: **Keep Notes** (default), **Delete Notes**
  (destructive), **Cancel**.
- Empty folder: **Delete “Work”?** — "The folder is empty." **Delete**,
  **Cancel**.
- Keep Notes → `delete_folder(id, keep_notes: true)`; Delete Notes →
  `keep_notes: false`. Same semantics as the CLI (§5). No undo beyond
  restoring the notes from Deleted.

### 13. Agent skill

`skills/rallo/SKILL.md` documents `--folder` on `note`/`remind`/`list`/
`search`, `move`, `folders`, `tags`, `list --tag`, `list --done`, and the
rule: run `rallo folders` first and use an existing name; ask the user
before `folder create`; never `folder delete`.

### 14. Releases

1. **Core and CLI** (§2–§9, §13): agents can file and list by folder and tag.
2. **Panel** (§10).
3. **Window** (§11–§12).

Each ships on its own. Every UI change is rendered, clicked through, and
screenshotted in Light and Dark Mode before it's called done (repo
CLAUDE.md). Tests use `RALLO_DATA_DIR`, never the real data directory.

## Out of scope

Subfolders, Smart Folders, folder colours or icons, manual folder order,
pinned notes, gallery view, locked or shared notes, renaming tags, purging
Deleted after 30 days, filing Services/Shortcuts captures into a folder.

## Consequences

- Schema v6; older Rallo versions refuse the migrated database
  (`INCOMPATIBLE_SCHEMA`), as with every migration. The pre-migration
  backup is automatic.
- Export v3 is not readable by older Rallo versions; v1 and v2 stay
  importable.
- The CLI grows by `move`, `folder create|rename|delete`, `folders`, `tags`,
  and flags on `note`, `remind`, `list`, `search`; `docs/cli-contract.md`
  documents them.
- Rallo shows in the Dock only while the Notes window is open.
