import AppKit

/// The Format menu's actions (0023 §4). The string edits are `NoteFormatting`'s; this applies them.
extension PlainTextView {
    private var canFormat: Bool { isEditable && !hasMarkedText() }

    /// `pair`: the empty pair this edit inserted; it stays hidden while the caret rests in its middle.
    func apply(_ edit: FormatEdit, actionName: String, pair: NSRange? = nil) {
        guard canFormat else { return }
        isEditingText = true  // the command's selection is its own; `NoteCaret` must not move it
        defer { isEditingText = false }
        let isMove = edit.range.length == 0 && edit.replacement.isEmpty
        if !isMove {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
            isEditingText = true
            undoManager?.setActionName(actionName)
        }
        if let pair { pendingPair = pair }
        setSelectedRange(edit.selection)
    }

    // MARK: Empty pair

    private func isEmptyPair(_ r: NSRange) -> Bool {
        let ns = string as NSString
        guard r.length >= 2, r.length % 2 == 0, NSMaxRange(r) <= ns.length else { return false }
        let half = r.length / 2
        let first = ns.substring(with: NSRange(location: r.location, length: half))
        return first == ns.substring(with: NSRange(location: r.location + half, length: half))
            && first.allSatisfy { "*~`".contains($0) }
    }

    /// The pending pair, if it is still empty and the caret is exactly in its middle.
    func pairHidden(at selection: NSRange) -> NSRange? {
        guard let pair = pendingPair, selection.length == 0, selection.location == pair.location + pair.length / 2,
              isEmptyPair(pair) else { return nil }
        return pair
    }

    /// Typing made the pair real, or the caret left it empty: forget it, or remove it.
    func settlePendingPair() {
        guard let pair = pendingPair else { return }
        guard isEmptyPair(pair) else { pendingPair = nil; return }
        guard pairHidden(at: selectedRange()) == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.removePendingPair(pair) }  // not inside the selection callback
    }

    private func removePendingPair(_ pair: NSRange) {
        guard pendingPair == pair, isEmptyPair(pair), pairHidden(at: selectedRange()) == nil, isEditable, !hasMarkedText() else { return }
        pendingPair = nil
        let sel = selectedRange()
        isEditingText = true
        defer { isEditingText = false }
        guard shouldChangeText(in: pair, replacementString: "") else { return }
        textStorage?.replaceCharacters(in: pair, with: "")
        didChangeText()
        isEditingText = true
        undoManager?.setActionName("Typing")
        let shift = { (p: Int) in p >= NSMaxRange(pair) ? p - pair.length : min(p, pair.location) }
        setSelectedRange(NSRange(location: shift(sel.location), length: max(shift(NSMaxRange(sel)) - shift(sel.location), 0)))
    }

    private func toggle(_ mark: InlineMark, _ name: String) {
        guard canFormat else { return }
        let selection = selectedRange()
        let edit = NoteFormatting.toggle(mark, text: string, selection: selection, marks: marks)
        let inserted = selection.length == 0 && edit.range.length == 0 && edit.replacement == mark.rawValue + mark.rawValue
        apply(edit, actionName: name, pair: inserted ? NSRange(location: edit.range.location, length: edit.replacement.utf16.count) : nil)
    }

    private func block(_ style: BlockStyle, _ name: String) {
        guard canFormat else { return }
        apply(NoteFormatting.setBlock(style, text: string, selection: selectedRange()), actionName: name)
    }

    @objc func formatBold(_ sender: Any?) { toggle(.bold, "Bold") }
    @objc func formatItalic(_ sender: Any?) { toggle(.italic, "Italic") }
    @objc func formatStrikethrough(_ sender: Any?) { toggle(.strike, "Strikethrough") }
    @objc func formatCode(_ sender: Any?) { toggle(.code, "Code") }
    @objc func formatHeading(_ sender: Any?) { block(.heading, "Heading") }
    @objc func formatSubheading(_ sender: Any?) { block(.subheading, "Subheading") }
    @objc func formatBody(_ sender: Any?) {
        // Inside a code block Body is its way out: Monostyled shows current there.
        if isActive(#selector(formatMonostyled(_:))) { formatMonostyled(sender) } else { block(.body, "Body") }
    }
    @objc func formatBulletedList(_ sender: Any?) { block(.bulleted, "Bulleted List") }
    @objc func formatNumberedList(_ sender: Any?) { block(.numbered, "Numbered List") }
    @objc func formatChecklist(_ sender: Any?) { block(.checklist, "Checklist") }
    @objc func formatBlockQuote(_ sender: Any?) { block(.quote, "Block Quote") }

    @objc func formatMonostyled(_ sender: Any?) {
        guard canFormat else { return }
        apply(NoteFormatting.toggleCodeBlock(text: string, selection: selectedRange(), marks: marks), actionName: "Monostyled")
    }

    @objc func formatMarkChecked(_ sender: Any?) {
        guard canFormat, let edit = NoteFormatting.toggleChecked(text: string, selection: selectedRange()) else { return }
        apply(edit, actionName: "Mark as Checked")
    }

    @objc func formatIncreaseIndent(_ sender: Any?) { indent(outdent: false, name: "Increase Indent") }
    @objc func formatDecreaseIndent(_ sender: Any?) { indent(outdent: true, name: "Decrease Indent") }

    @discardableResult
    private func indent(outdent: Bool, name: String) -> Bool {
        guard canFormat, let edit = NoteFormatting.indent(text: string, selection: selectedRange(), outdent: outdent) else { return false }
        apply(edit, actionName: name)
        return true
    }

    @objc func formatAddLink(_ sender: Any?) {
        guard canFormat else { return }
        apply(NoteFormatting.addLink(text: string, selection: selectedRange()), actionName: "Add Link")
    }

    @objc func formatInsertDivider(_ sender: Any?) {
        guard canFormat else { return }
        apply(NoteFormatting.insertDivider(text: string, selection: selectedRange()), actionName: "Insert Divider")
    }

    // MARK: State

    func isActive(_ action: Selector) -> Bool {
        let start = selectedRange().location
        let inline: [Selector: InlineMark] = [
            #selector(formatBold(_:)): .bold, #selector(formatItalic(_:)): .italic,
            #selector(formatStrikethrough(_:)): .strike, #selector(formatCode(_:)): .code,
        ]
        if let mark = inline[action] { return NoteFormatting.isInside(mark, location: start, marks: marks) }
        let blocks: [Selector: BlockStyle] = [
            #selector(formatHeading(_:)): .heading, #selector(formatSubheading(_:)): .subheading,
            #selector(formatBulletedList(_:)): .bulleted, #selector(formatNumberedList(_:)): .numbered,
            #selector(formatChecklist(_:)): .checklist, #selector(formatBlockQuote(_:)): .quote,
        ]
        if let style = blocks[action] { return NoteFormatting.blockStyle(text: string, at: start) == style }
        let inCode = marks.contains { $0.kind == .codeBlock && start >= Int($0.utf16Start) && start <= Int($0.utf16Start + $0.utf16Len) }
        if action == #selector(formatMonostyled(_:)) { return inCode }
        if action == #selector(formatBody(_:)) { return !inCode && NoteFormatting.blockStyle(text: string, at: start) == .body }
        return false
    }

    private static let formatActions: Set<Selector> = [
        #selector(formatBold(_:)), #selector(formatItalic(_:)), #selector(formatStrikethrough(_:)), #selector(formatCode(_:)),
        #selector(formatHeading(_:)), #selector(formatSubheading(_:)), #selector(formatBody(_:)), #selector(formatMonostyled(_:)),
        #selector(formatBulletedList(_:)), #selector(formatNumberedList(_:)), #selector(formatChecklist(_:)),
        #selector(formatMarkChecked(_:)), #selector(formatBlockQuote(_:)), #selector(formatIncreaseIndent(_:)),
        #selector(formatDecreaseIndent(_:)), #selector(formatAddLink(_:)), #selector(formatInsertDivider(_:)),
    ]

    /// `nil`: not a format action, so the caller defers to `super`.
    func validateFormat(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = item.action, Self.formatActions.contains(action) else { return nil }
        if let menuItem = item as? NSMenuItem { menuItem.state = isActive(action) ? .on : .off }
        // Nil-target actions also reach the main window's chain: a key panel (notes panel, Transfer) must not
        // edit this window's note. The Aa popover is a child window and keeps it.
        // Validate only: the popover's `sendAction(to:)` runs the action directly.
        return isEditable && (window?.isKeyWindow == true || NSApp.keyWindow?.parent === window)
    }

    // MARK: Keys

    func handleNewline() -> Bool {
        guard canFormat, let edit = NoteFormatting.newline(text: string, selection: selectedRange(), marks: marks) else { return false }
        apply(edit, actionName: "Typing")
        return true
    }

    func handleTab(outdent: Bool) -> Bool { indent(outdent: outdent, name: outdent ? "Decrease Indent" : "Increase Indent") }

    // MARK: Mouse

    /// A click on a task box toggles it; ⌘-click on link text opens it. True when handled.
    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard let layout = layoutManager as? NoteLayoutManager, let container = textContainer else { return false }
        let origin = textContainerOrigin
        let click = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: click.x - origin.x, y: click.y - origin.y)
        let ns = string as NSString

        if isEditable {
            for span in marks {
                guard case .taskBox = span.kind else { continue }
                let range = NSRange(location: Int(span.utf16Start), length: Int(span.utf16Len))
                guard NSMaxRange(range) <= ns.length, layout.boxRect(forCharacterRange: range)?.contains(point) == true else { continue }
                let saved = selectedRange()
                if var edit = NoteFormatting.toggleChecked(text: string, selection: ns.paragraphRange(for: range)) {
                    edit.selection = saved // `[ ]` ↔ `[x]` keeps the length: nothing shifts
                    apply(edit, actionName: "Mark as Checked")
                }
                return true
            }
        }

        if event.modifierFlags.contains(.command) {
            let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            guard let text = marks.first(where: {
                $0.kind == .linkText && index >= Int($0.utf16Start) && index <= Int($0.utf16Start + $0.utf16Len)
            }), let url = marks.first(where: { $0.kind == .linkUrl && $0.utf16Start >= text.utf16Start + text.utf16Len }) else { return false }
            let range = NSRange(location: Int(url.utf16Start), length: Int(url.utf16Len))
            guard NSMaxRange(range) <= ns.length, let target = URL(string: ns.substring(with: range)),
                  let scheme = target.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return false }
            NSWorkspace.shared.open(target)
            return true
        }
        return false
    }
}
