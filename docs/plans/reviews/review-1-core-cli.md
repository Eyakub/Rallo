# Review: docs/plans/2026-10-08-folders-1-core-cli.md (HEAD 855c1b1)

Method: spec 0019, 0003, 0004, cli-contract and every touched source file read; Tasks 1-2 applied
verbatim (extracted from the plan file) in a scratch clone and run: `cargo fmt --check`,
`cargo clippy --workspace --all-targets -D warnings`, `cargo test -p rallo-core --test migrations
--test images --lib tags`, `cargo test -p rallo-cli --test cli version_json` -- all green, the v5->v6
migration on a populated DB included. Tasks 3-8 reviewed statically against the real code (struct
literal sites, column lists, exhaustive matches, diff anchors, FFI/Swift callers, spec §9 names).
Task 7 matches spec §9 exactly (records, enums, method names/params, ItemPage+cursor,
cancel_reminder, FolderSnapshot.note_count, TagRange covering `#`, §4 error categories).

Counts: BLOCKER 0, MAJOR 2, MINOR 10.

---

## MAJOR

### M1. ZWJ/ZWNJ end a Bangla tag (Task 2, `is_tag_char`; spec §7 grammar)
Verified with the compiled parser: `tags("#র\u{200D}্যালো")` -> `["র"]`. U+200C/U+200D are Cf, so
the spec regex `[\p{L}\p{M}\p{N}_-]*` stops at them, but Bangla conjuncts spell them in
(র‍্য = "rya"; the app's own name in Bangla is র‍্যালো). The plan is faithful to the spec, so this is
a spec gap the plan must surface rather than silently inherit; a one-line fix once agreed:
```rust
fn is_tag_char(c: char) -> bool {
    is_letter(c) || is_mark(c) || is_number(c) || matches!(c, '-' | '_' | '\u{200C}' | '\u{200D}')
}
```
plus a test `assert_eq!(tags("#র\u{200D}্যালো"), ["র\u{200d}্যালো"]);` and the §7 regex amended to
`[\p{L}\p{M}\p{N}‌‍_-]*`. The range stays correct (ZWJ is one UTF-16 unit, counted by
`len_utf16`). Decide before Task 2 ships: `rallo_has_tag` and the FFI `tag_ranges` both change behaviour.

### M2. Flaky test: `two_folders_in_one_file_with_the_same_name_key_become_one` (Task 6 Step 1)
`document["items"][1]["folder_id"] = json!(twin)` assumes `items[1]` is the loose note. Export
orders `created_at_ms ASC, id ASC`; `source()` creates both notes with the system clock, and when
they land in the same millisecond the tie is broken by random UUID, so `items[1]` is the work note
roughly half the time and the final assertion `folder_of(loose_note) == Some("Work")` fails with
correct code. Fix: locate by text.
```rust
let loose = document["items"].as_array_mut().unwrap().iter_mut().find(|i| i["text"] == "loose note").unwrap();
loose["folder_id"] = json!(twin);
```
(`bad_folder_data_is_invalid_import_and_writes_nothing` uses `items[0]` too, but any item works there.)

---

## MINOR

### m1. `folder_create` receipt fingerprint uses the name key; `folder_rename` uses the raw name (Task 3 Step 4)
0003 §7: fingerprints are the *original* inputs ("the raw --text, not its match key"). With the key,
`folder create Work --request-id x` then `folder create WORK --request-id x` replays "Work" instead
of `REQUEST_ID_CONFLICT`, while the same pair on `rename` conflicts. Make create use the trimmed raw
name: `CreateInputs { command: "folder_create", name: &name }` (and the test line
`store.create_folder("work", Some("create-1"))` becomes `"Work"`). Rename is already right (a
case-only rename *is* a different input).

### m2. `validate_name` accepts U+2028/U+2029 (Task 3 Step 4)
Spec §3: "no control characters or line breaks". `char::is_control` is Cc only; LINE SEPARATOR and
PARAGRAPH SEPARATOR (Zl/Zp) pass. Fix:
```rust
if name.chars().any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')) {
```
and add `"a\u{2028}b"` to the bad list in `names_are_trimmed_and_limited_to_fifty_characters...`.

### m3. Tag keys are lowercased but not NFC-normalised (Task 2)
Verified: `#e\u{301}cole` and `#école` are two different tags (keys `"e\u{301}cole"` vs `"école"`),
whereas folder keys go through NFC. Spec §7 only says "lowercased", so this is spec-level; the
cheapest fix is `key = text::match_key(&raw)` (trim+NFC+case fold, already the item rule) in
`tag_ranges`, with the spec line changed to "its text normalised like `match_key`". Low frequency on
macOS (keyboards emit precomposed), so MINOR; decide with M1 since both touch §7.

### m4. CSV-named folders are created even when every row naming them is `identical` (Task 6 Step 4)
`plan_folders` collects `RecordFolder::Named` from *all* records before classification, so an
id-less CSV row that dedupes as identical (text+created_at) still creates its folder, resurrecting a
folder the user deleted as an empty one and counting it in `new_folders`. Rows with ids are safe
(they conflict instead). Fix: compute decisions first and only plan `Named` folders for `New`
records -- in `classify_collect`, run `plan_folders` with the document folders only, classify, then
extend `plan.create` from the `New` records' names. Or document the edge in 0019 §8.

### m5. JSON test does not isolate "differs only by folder" (Task 6 Step 1)
`an_existing_note_that_differs_only_by_folder_is_a_conflict_and_nothing_is_written` uses
`move_item`, which also bumps `updated_at_ms`/`revision`; JSON records carry `updated_at_ms`, so the
conflict usually fires on the timestamp, not the folder. The CSV variant (raw `UPDATE items SET
folder_id = NULL`) does isolate it. Use the same raw UPDATE here so the test proves what its name says.

### m6. `TagCount` is added to `folders/model.rs` in Task 3 only to be moved in Task 4 (Task 3 Step 4, Task 4 Step 3)
The Task 4 removal hunk sits between two identical `pub open_count: u64,` context lines, which is
easy to mis-apply by hand. Define `TagCount` once, in `items/model.rs`, in Task 3 (nothing in Task 3
uses it), and drop both the Task 3 re-export and the Task 4 move.

### m7. Replayed folder receipts return the stored outcome, not the current folder (Task 3 Step 4)
0003 §7: a replay returns the stored result "combined with the current snapshot". A replayed
`folder_create`/`folder_rename` reports the folder as it was (name, revision) even if it has since
been renamed or deleted. Accepted as a plan decision; either note it in `docs/cli-contract.md`'s
`folder` rows or re-read the folder by id on replay (`repository::get(&tx, outcome.folder.id)`) and
fall back to the stored copy when it is gone.

### m8. `Move` subcommand flags have no help text (Task 5 Step 3)
`request_id`/`if_revision` on `Move` (and on `FolderCommand::*`) lack the `///` doc comments every
other command's flags carry, so `rallo move --help` shows blank descriptions. Copy the two lines
from `Edit`.

### m9. Task 7 Step 7's `swiftc -typecheck` is unlikely to pass as written
`CoreBridgeTests.swift` is an XCTest file; type-checking it outside the test bundle needs the
XCTest framework path *and* module context, and the project's test target also compiles
`CoreClient.swift`. The step already says "skip it if picky"; make it explicit by deleting the
`swiftc` lines (Step 8's `xcodebuild test` compiles the same files) so a worker does not burn time
on it. Keep the two `grep` lines and `git status --short apps/macos/Rallo/Generated`.

### m10. Stale statements in the plan text
- Self-Review: "`docs/decisions/0019-folders-and-tags.md` has uncommitted edits" and Final
  Verification Step 4 "whatever the user has pending in 0019": the spec is committed (855c1b1);
  `git status` shows only `assets/pet/rallo/launch-kit/` and `marketing/`. Delete both sentences.
- Task 6 Step 5 hunk header `@@ -1220,6 +1220,7 @@`: `import_fields` is at line ~1055 of a
  1186-line file. Context lines match, so it applies; just a wrong number.

---

## Checked and found correct (so the orchestrator need not re-derive)
- Migration: `ALTER TABLE ... REFERENCES` with `foreign_keys` ON inside `BEGIN IMMEDIATE` on a
  populated v5 DB works; FK enforced; partial index present; data untouched (ran the test).
- `rallo_has_tag`: deterministic, NULL-safe, registered in `Store::open` (the only connection that
  runs item queries; doctor/inspect/backup connections never reference it; no schema object uses it).
- Delete path: `soft_delete` = `mark_deleted` + `disable_active` (cancel intent + supersede) shared
  by `delete`, `delete --text`, `folder delete --delete-notes`; one `change_revision` bump; +2
  revision per spec §5; `clear_items` precedes `DELETE FROM folders`, so the FK never fires.
- `move`: receipt -> resolve -> ITEM_DELETED -> FOLDER_NOT_FOUND -> no-op -> revision -> mutate.
- Cursors/total_count: the `Filter` body is counted before the cursor clause is appended; anonymous
  `?` + `params_from_iter` keep order; `Done` sorts `(completed_at_ms, id) DESC`.
- Receipts: `CreateNoteInputs.folder` is last and skipped for Notes, so pre-folder receipts still match.
- Import: v1/v2 -> `Unspecified` (never compared, new notes to Notes); v3 `folder_id: null` -> Notes
  and compared; rules 1-3 in document order with no UNIQUE path; plan recomputed inside the write
  transaction; zip path shares the parser; CSV `folder` column formula-guarded both ways.
- No environment risk: temp dirs everywhere, `RALLO_DATA_DIR=$(mktemp -d)` for the manual pass,
  `build-macos.sh` without `--install`, `RalloTests` is an unhosted `bundle.unit-test`, `lsregister -u`
  on the scratch build, named-path `git add`, author line matches history (`Eyakub <eyakubsorkar@gmail.com>`).
- Compile-affecting sites all covered: 4 `Item {}` literals, 1 `ItemView {}` literal, 1 explicit
  item column list (`due_page`), no `ListFilter` `match` outside `repository::list`, no Swift
  memberwise `ItemSnapshot(...)`/`ImportSummary(...)` constructors, `insert_reminder` already has
  `#[allow(clippy::too_many_arguments)]`, `Store::cancel_reminder(&str, &MutationOptions)` exists.

## Note for releases 2 and 3 (not findings against this plan)
Their drafts call `listItems(kind:scope:tag:limit:)` and `searchItems(query:limit:)` without
`cursor:` and wrap `renameFolder(_:to:)`; Task 7 (and spec §9) have `cursor:` and return `ItemPage`.
Fix those plans to the spec, as intended.
