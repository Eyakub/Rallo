import AppKit

/// What Backspace, Forward Delete and typing over a selection do when Markdown marks are hidden: the marks
/// never get in the way (0023 §3). Pure: UTF-16 ranges; the text view applies the returned edits.
enum NoteDeleting {
    enum Action: Equatable {
        case edit(FormatEdit)
        case move(Int)
        case none  // swallow the key
    }

    private typealias Span = (kind: MarkdownKind, range: NSRange)

    private static func spans(_ marks: [MarkdownSpan]) -> [Span] {
        marks.map { ($0.kind, NSRange(location: Int($0.utf16Start), length: Int($0.utf16Len))) }
    }

    private static let contentKinds: [MarkdownKind] = [.bold, .italic, .strike, .code, .linkText]

    /// Each styled span as (content, opening mark, closing mark): a link's closer is its `](url)`.
    private static func pairs(_ marks: [MarkdownSpan]) -> [(content: NSRange, open: NSRange, close: NSRange)] {
        let all = spans(marks)
        let markers = all.filter { $0.kind == .marker }.map(\.range)
        return all.compactMap { kind, r in
            guard contentKinds.contains(kind), let open = markers.first(where: { NSMaxRange($0) == r.location }),
                  let close = markers.first(where: { $0.location == NSMaxRange(r) }) else { return nil }
            return (r, open, close)
        }
    }

    private static func remove(_ r: NSRange) -> FormatEdit {
        FormatEdit(range: r, replacement: "", selection: NSRange(location: r.location, length: 0))
    }

    /// Deleting `r` (one character): when it is all of a span's content, the span goes with its marks.
    private static func deleting(_ r: NSRange, marks: [MarkdownSpan]) -> FormatEdit {
        let pairs = pairs(marks)
        var r = r
        while let pair = pairs.first(where: { $0.content == r }) {
            r = NSUnionRange(pair.open, pair.close)
        }
        return remove(r)
    }

    private static func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    /// A divider's paragraph, with the line break before it when it ends the text.
    private static func dividerParagraph(_ run: NSRange, in text: NSString) -> NSRange {
        var r = text.paragraphRange(for: run)
        if NSMaxRange(r) == text.length, r.location > 0, !isNewline(text.character(at: text.length - 1)) {
            r = NSRange(location: r.location - 1, length: r.length + 1)
        }
        return r
    }

    /// `nil`: nothing special, AppKit's own Backspace does it.
    static func backspace(text: NSString, caret c: Int, marks: [MarkdownSpan], runs: [NoteCaret.Run]) -> Action? {
        let length = text.length
        // The content start of a heading, quote or list line: Backspace removes the block mark.
        if runs.contains(where: {
            $0.side == .end && NSMaxRange($0.range) == c && $0.range.location == text.paragraphRange(for: NSRange(location: $0.range.location, length: 0)).location
        }) {
            return .edit(NoteFormatting.setBlock(.body, text: text as String, selection: NSRange(location: c, length: 0)))
        }
        // Right after a hidden divider or fence line.
        if let run = runs.first(where: { $0.side == .line && NSLocationInRange(c - 1, $0.range) }) {
            let all = spans(marks)
            if all.contains(where: { $0.kind == .divider && NSIntersectionRange($0.range, run.range).length > 0 }) {
                return .edit(remove(dividerParagraph(run.range, in: text)))
            }
            guard let block = all.first(where: { $0.kind == .codeBlock && NSIntersectionRange($0.range, run.range).length > 0 }) else { return nil }
            let fenceStarts = all.filter { $0.kind == .codeFence }.map(\.range.location)
            let opening = run.range.location == block.range.location
            let emptyBlock = fenceStarts.contains(NSMaxRange(run.range))
            if opening || emptyBlock || c != NSMaxRange(run.range) {
                return .edit(NoteFormatting.toggleCodeBlock(text: text as String, selection: NSRange(location: c, length: 0), marks: marks))
            }
            return .move(run.range.location - 1)  // the closer never deletes: step to the end of the last code line
        }
        // Hidden marks sit before the caret: delete the character before them.
        if let spot = NoteCaret.hiddenSpot(at: c, runs: runs, length: length), !spot.isLine, c > spot.lo {
            guard spot.lo > 0 else { return Action.none }
            return .edit(deleting(text.rangeOfComposedCharacterSequence(at: spot.lo - 1), marks: marks))
        }
        guard c > 0 else { return nil }
        let r = text.rangeOfComposedCharacterSequence(at: c - 1)
        let edit = deleting(r, marks: marks)
        return edit.range == r ? nil : .edit(edit)
    }

    static func forwardDelete(text: NSString, caret c: Int, marks: [MarkdownSpan], runs: [NoteCaret.Run]) -> Action? {
        let length = text.length
        if let spot = NoteCaret.hiddenSpot(at: c, runs: runs, length: length), !spot.isLine, c < spot.hi {
            guard spot.hi < length else { return Action.none }
            return .edit(deleting(text.rangeOfComposedCharacterSequence(at: spot.hi), marks: marks))
        }
        guard c < length else { return nil }
        // A hidden line starts right after this line's break: a divider goes, a fence stays.
        if isNewline(text.character(at: c)), let run = runs.first(where: { $0.side == .line && $0.range.location == c + 1 }) {
            let isDivider = spans(marks).contains { $0.kind == .divider && NSIntersectionRange($0.range, run.range).length > 0 }
            return isDivider ? .edit(remove(dividerParagraph(run.range, in: text))) : Action.none
        }
        let r = text.rangeOfComposedCharacterSequence(at: c)
        let edit = deleting(r, marks: marks)
        return edit.range == r ? nil : .edit(edit)
    }

    /// Deleting or typing over a selection. Deleting (`replacement` nil) widens over the marks of every
    /// span whose content the selection covers entirely; both remove the partner of any mark they remove.
    /// Typing keeps the marks around fully selected content (a selected bold word typed over stays bold).
    static func ranged(text: NSString, selection: NSRange, marks: [MarkdownSpan], replacement: String?) -> FormatEdit {
        let selection = NSIntersectionRange(selection, NSRange(location: 0, length: text.length))
        let pairs = pairs(marks)
        var removed = [selection]
        func touched(_ m: NSRange) -> Bool { removed.contains { NSIntersectionRange($0, m).length > 0 } }
        if replacement == nil {
            for p in pairs where p.content.location >= selection.location && NSMaxRange(p.content) <= NSMaxRange(selection) {
                removed += [p.open, p.close]
            }
        }
        var grew = true
        while grew {  // a removed mark takes its partner, which may take another pair's mark
            grew = false
            for p in pairs where touched(p.open) != touched(p.close) {
                removed += [p.open, p.close]
                grew = true
            }
        }
        var merged: [NSRange] = []
        for r in removed.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, r.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, r) } else { merged.append(r) }
        }
        let hull = NSUnionRange(merged[0], merged[merged.count - 1])
        var kept = "", cursor = hull.location, before = 0
        for r in merged {
            kept += text.substring(with: NSRange(location: cursor, length: r.location - cursor))
            cursor = NSMaxRange(r)
            before += max(min(NSMaxRange(r), selection.location) - r.location, 0)
        }
        let at = selection.location - before  // the selection start, in the text without the removed marks
        let index = min(max(at - hull.location, 0), (kept as NSString).length)
        let typed = replacement ?? ""
        let out = (kept as NSString).replacingCharacters(in: NSRange(location: index, length: 0), with: typed)
        return FormatEdit(range: hull, replacement: out, selection: NSRange(location: at + (typed as NSString).length, length: 0))
    }
}

extension PlainTextView {
    private var canEditMarks: Bool {
        let length = (string as NSString).length
        return isEditable && !hasMarkedText() && !marks.contains { Int($0.utf16Start + $0.utf16Len) > length }  // stale marks: AppKit's rules
    }

    private func hiddenRuns() -> [NoteCaret.Run] {
        let text = string as NSString
        let shown = NoteTextStyler.linkReveal(in: text, selection: selectedRange(), marks: marks)
        return NoteCaret.runs(text: text, marks: marks, shown: shown)
    }

    /// True when handled. An empty pair that was just inserted goes whole.
    private func deleteHidden(forward: Bool) -> Bool {
        guard canEditMarks else { return false }
        let selection = selectedRange()
        let text = string as NSString
        if selection.length > 0 {
            apply(NoteDeleting.ranged(text: text, selection: selection, marks: marks, replacement: nil), actionName: "Delete")
            return true
        }
        if let pair = pairHidden(at: selection) {
            pendingPair = nil
            apply(FormatEdit(range: pair, replacement: "", selection: NSRange(location: pair.location, length: 0)), actionName: "Delete")
            return true
        }
        let runs = hiddenRuns()
        let action = forward
            ? NoteDeleting.forwardDelete(text: text, caret: selection.location, marks: marks, runs: runs)
            : NoteDeleting.backspace(text: text, caret: selection.location, marks: marks, runs: runs)
        switch action {
        case nil: return false
        case .some(.none): return true
        case .some(.move(let p)):
            isEditingText = true
            setSelectedRange(NSRange(location: p, length: 0))
            isEditingText = false
            return true
        case .some(.edit(let edit)):
            apply(edit, actionName: "Delete")
            return true
        }
    }

    // ponytail: only the single-character deletes and selections know about hidden marks. ⌥⌫, ⌘⌫ and the
    // other word/line deletes run AppKit's own and can orphan a mark, which then shows as literal text.
    // Upgrade: route them through `NoteDeleting.ranged` with the range AppKit would delete.
    override func deleteBackward(_ sender: Any?) {
        if !deleteHidden(forward: false) { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if !deleteHidden(forward: true) { super.deleteForward(sender) }
    }

    override func delete(_ sender: Any?) {
        if !(selectedRange().length > 0 && deleteHidden(forward: false)) { super.delete(sender) }
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0, canEditMarks else { return super.cut(sender) }
        copy(sender)
        _ = deleteHidden(forward: false)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard canEditMarks, replacementRange.location == NSNotFound else { return super.insertText(string, replacementRange: replacementRange) }
        let typed = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let text = self.string as NSString
        let selection = selectedRange()
        if selection.length > 0 {
            let edit = NoteDeleting.ranged(text: text, selection: selection, marks: marks, replacement: typed)
            if edit.range != selection { return apply(edit, actionName: "Typing") }
        } else if hiddenRuns().contains(where: { $0.side == .line && NSMaxRange($0.range) == text.length && selection.location >= $0.range.location }) {
            // The caret sits on a collapsed last line (a closing fence or divider ends the note): type on a new line.
            let line = "\n" + typed
            return apply(
                FormatEdit(range: NSRange(location: text.length, length: 0), replacement: line,
                           selection: NSRange(location: text.length + (line as NSString).length, length: 0)),
                actionName: "Typing")
        }
        super.insertText(string, replacementRange: replacementRange)
    }
}
