# 0023 — Rich text in notes

- **Status:** accepted (user, 2026-10-19: "go with B"; §3 amended 2026-10-19: marks never show)
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

### 3. Marks never show (user, 2026-10-19, replacing option B)

Marks never show: not on the caret's line, not inside a code block ("No **
or * anywhere, ever"). Bold, italic, headings and so on show styled; their
marks (`**`, `# `, `> `, `](url)`, fence lines, `---` lines) are hidden by
attributes only (a 0.01 pt clear font, and a collapsed paragraph style for
fence lines), so the editor's off-screen height measurement sees it.
Bullets, numbers and checkboxes are drawn in place of their marks. Storage
stays Markdown; the panel's quick editor still shows it raw.

- **Link exception.** A link shows all its marks, dimmed, while the editor
  is focused and the caret is strictly inside `[`…`)`, or a ranged selection
  touches it. ⌘K and editing a URL need it. Entering or leaving restyles
  the link's paragraph, never while the mouse is down, then re-measures.
- **Empty pair.** ⌘B on an empty selection still inserts `**|**`; the parser
  rejects empty content, so the pair is hidden (`PlainTextView.pendingPair`)
  while the caret is in its middle. Typing makes it a real span; moving the
  caret elsewhere, or Backspace, removes it.
- **Caret.** Hidden marks are characters, so `NoteCaret` makes each hidden
  run one visual spot. A click rests at the run's content side (before an
  opener, after a closer, after a block prefix); an arrow key steps over the
  whole run; a hidden fence or divider line is skipped. Snapping runs in the
  selection delegate, never during an edit (typing, Return, format commands,
  undo), so after `**|**` and a letter the caret stays before the hidden
  closer and the next letter is bold.
- **Editing.** Backspace after a closer deletes the character before it;
  forward delete before an opener, the one after it. At a heading, quote or
  list line's content start, Backspace removes the block mark (Body). After
  a hidden divider it deletes the divider; after an opening fence it removes
  both fences; after a closing fence it only moves to the end of the code.
  Deleting a span's only character deletes the span with its marks. A
  deleted or cut selection takes the marks of every span it covers whole,
  and the partner of any mark it removes; typing over a selection keeps the
  marks (a selected bold word typed over stays bold). Typing on a collapsed
  last line (a fence or divider ends the note) starts a new line.
- **Ceiling.** ⌥⌫, ⌘⌫ and other word or line deletes run AppKit's own rules
  and can orphan a mark, which then shows as literal text.

Superseded: option B (marks dimmed on the caret's line, both fences while the
caret was in a code block). It re-wrapped a line whenever the caret entered
or left it, which the user no longer wants to see.

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
