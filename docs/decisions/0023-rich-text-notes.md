# 0023 — Rich text in notes

- **Status:** accepted (user, 2026-10-19: "go with B")
- **Date:** 2026-10-19
- **Mockup:** `docs/mockups/rich-text.html`
- **Related:** 0019 §7 (tags), §11 (the window's editor), 0018 (note rows),
  0003 (64 KiB note text), plan `docs/plans/2026-10-19-rich-text.md`

## Context

The Notes window's editor is a plain-text `NSTextView` (0019 §11). ⌘B does
nothing: there is no Format menu and the view is not rich text. The user
wants formatting like Apple Notes and Notion: bold, lists, checklists,
headings, with the usual shortcuts.

A note's text is shared with the CLI, agents (which already write Markdown),
search, export/import, tags, notifications and the pet's bubble.

## Decision

### 1. The note stays Markdown in `items.text`

No schema, FFI-type, CLI-contract or export change. The editor styles the
Markdown by attributes, as it styles tags today; the string holds exactly
what the user typed (or what a format command wrote). `isRichText` stays
false and paste stays plain text.

Rejected: storing rich text (RTF, spans) beside or instead of the text. It
splits the truth between the app and the CLI and needs a migration.

### 2. A small grammar, not CommonMark

`rallo-core/src/items/markdown.rs` parses only these, line by line; anything
else is literal text:

| Kind | Syntax |
|---|---|
| Heading | `# ` (Heading), `## ` and deeper (Subheading) at line start |
| Bulleted list | `- `, `* `, `+ ` after optional indent |
| Numbered list | `1. ` or `1) ` after optional indent |
| Checklist | a bullet then `[ ] ` / `[x] ` / `[X] ` (or the box at line end) |
| Block quote | `> ` (or `>`) at line start |
| Code block | a ```` ``` ```` line (up to 3 spaces in) opens; the next one closes; unclosed runs to the end |
| Divider | `---`, `***` or `___` (3 or more, nothing else on the line) |
| Bold | `**text**` |
| Italic | `*text*`, or `_text_` with no letter or digit outside the `_` |
| Strikethrough | `~~text~~` |
| Code | `` `text` `` (any backtick run, closed by the same length) |
| Link | `[text](url)`, url without spaces |
| Escape | `\` before ASCII punctuation |

Inline marks never cross a line. An opener must be followed by a non-space
and a closer preceded by one, and the content is not empty (`5 * 3 * 2`
stays literal). Code spans and links are found first; emphasis marks inside
them are literal. `__` and `***` are not marks. A `#tag` needs a letter
right after `#`, a heading needs `# `, so the two never collide.

CommonMark's setext headings (`---` under a line), indented code blocks and
HTML would restyle existing plain notes; they are left out on purpose. The
grammar still writes Markdown that other tools render.

The FFI exposes `markdown_spans(text)` (UTF-16 ranges, like `tag_ranges`)
and `plain_text(text)` (marks removed, line breaks kept).

### 3. Marks hide off the caret's line (option B)

Bold, italic, headings and so on show styled; their marks (`**`, `# `,
`](url)`, fence lines) are hidden except on the line(s) the selection
touches while the editor is focused, where they show dimmed. Every line of a
code block shows its fences while the caret is anywhere in the block.
Bullets, numbers and checkboxes are drawn in place of their marks on every
line.

Hiding is by attributes only (a 0.01 pt clear font, and a collapsed
paragraph style for fence lines), so the editor's off-screen height
measurement sees it. Measured: a hidden `**` adds 0.02 pt, a hidden fence
line 0.01 pt. Moving the caret restyles only the old and new lines, never
while the mouse is down, then re-measures.

The cost the user accepted: a line re-wraps when the caret enters or leaves
it.

### 4. Shortcuts: Apple Notes'

Read from Notes.app's own menu. Format menu, between Edit and Window:

| Item | Keys | Writes |
|---|---|---|
| Heading | ⇧⌘H | `# ` |
| Subheading | ⇧⌘J | `## ` |
| Body | ⇧⌘B | removes the line's block mark |
| Monostyled | ⇧⌘M | wraps the lines in ```` ``` ```` fences |
| Bulleted List | ⇧⌘7 | `- ` |
| Numbered List | ⇧⌘9 | `1. `, `2. `… |
| Checklist | ⇧⌘L | `- [ ] ` |
| Mark as Checked | ⇧⌘U | `[ ]` ↔ `[x]` |
| Block Quote | ⌘' | `> ` |
| Font › Bold | ⌘B | `**` |
| Font › Italic | ⌘I | `*` |
| Font › Strikethrough | ⇧⌘X | `~~` (Notes has no key; Slack's) |
| Font › Code | ⌘E | `` ` `` (Notes has no key; Notion's) |
| Indentation › Increase / Decrease | ⌘] / ⌘[ | two spaces on list lines |
| Add Link… | ⌘K | `[selection](` caret `)` |
| Insert Divider | ⌘L | `---` on its own line |

There is no Title style: the first line already is the title (0018). Block
commands toggle: applied to lines that all have the style, they remove it.
An inline command on a selection inside that style removes it; on an empty
selection it inserts the pair and puts the caret between; again on the empty
pair, it removes it; inside the style just before its closing mark, it steps
past the mark. A selection over several lines gets the mark per line.

Return in a list item continues the list (next number, an empty box); on an
empty item it ends the list. Tab and ⇧Tab indent and outdent list items.
Clicking a checkbox toggles it. ⌘-click on a link opens `http`, `https` and
`mailto` URLs.

The actions have Rallo's own selector names, so the panel's SwiftUI text
views never answer them; the panel's ⌘E (edit a row) is unchanged.

### 5. Toolbar

The editor's toolbar gains **Aa** (a popover: Heading, Subheading, Body,
Monostyled; Bold, Italic, Strikethrough, Code, Link; lists, quote, indent)
and a Checklist button. The popover acts on the editor directly, not
through the responder chain, since it can take key focus.

### 6. Everywhere else shows plain text

List rows, panel rows, toasts and VoiceOver names (`NoteParts`/`RowText`),
the pet's bubble (`SummonBubbleContent.excerpt`) and notification previews
(`title_and_body`) use `plain_text`. The CLI, export/import, search
(`match_key`) and tags keep the stored text. A phrase search across a mark
(`rich text in` over `**rich text** in`) does not match; single words do.
The panel's inline editor shows the Markdown as stored.

### 7. Not now

Underline and highlight (no Markdown form), converting rich paste to
Markdown, a Notion-style selection bar, a slash menu, renumbering a
numbered list after edits, nested quotes.
