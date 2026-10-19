import AppKit

/// The Format menu's actions (0023 §4). The string edits are `NoteFormatting`'s; this applies them.
extension PlainTextView {
    private var canFormat: Bool { isEditable && !hasMarkedText() }

    func apply(_ edit: FormatEdit, actionName: String) {
        guard canFormat else { return }
        let isMove = edit.range.length == 0 && edit.replacement.isEmpty
        if !isMove {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
            undoManager?.setActionName(actionName)
        }
        setSelectedRange(edit.selection)
    }

    private func toggle(_ mark: InlineMark, _ name: String) {
        guard canFormat else { return }
        apply(NoteFormatting.toggle(mark, text: string, selection: selectedRange(), marks: marks), actionName: name)
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
    @objc func formatBody(_ sender: Any?) { block(.body, "Body") }
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
        return isEditable
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
                if let edit = NoteFormatting.toggleChecked(text: string, selection: ns.paragraphRange(for: range)) {
                    apply(edit, actionName: "Mark as Checked")
                    setSelectedRange(saved) // `[ ]` ↔ `[x]` keeps the length: nothing shifts
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
