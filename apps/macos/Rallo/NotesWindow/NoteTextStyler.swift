import AppKit

/// The editor's text view: plain text only. Paste drops fonts, colours and attachments.
final class PlainTextView: NSTextView {
    /// The Markdown spans of the current text, set by the coordinator on each full restyle.
    var marks: [MarkdownSpan] = []

    /// TextKit 1 (the editor measures with its layout manager), plain text, no
    /// smart quotes or dashes rewriting what the user typed.
    static func make() -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        // A rust wash; no foreground colour, so selected text keeps its ink/rust.
        view.selectedTextAttributes = [.backgroundColor: Theme.textSelectionNS]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.replaceLayoutManager(NoteLayoutManager())
        return view
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

enum NoteTextStyler {
    /// Pass dynamic colours (`Theme.inkNS`, `Theme.rustNS`): they resolve in the
    /// view's appearance when drawn, so Light/Dark needs no restyle.
    struct Palette {
        var ink: NSColor
        var rust: NSColor
        var bark: NSColor = Theme.barkNS
        var marker: NSColor = Theme.markerNS
        var codeBackground: NSColor = Theme.codeBackgroundNS
        var quoteBar: NSColor = Theme.quoteBarNS
        var divider: NSColor = Theme.dividerNS
    }

    /// Hides a run by size and colour only: the characters stay, so the string,
    /// the caret and the throwaway height measurement see the same text.
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    static func font(size: CGFloat, weight: NSFont.Weight, rounded: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The paragraph of `selection`, grown to every code block it touches, so a
    /// caret inside a block shows both fences.
    static func revealRange(in text: NSString, selection: NSRange, marks: [MarkdownSpan]) -> NSRange {
        let loc = min(selection.location, text.length)
        let selection = NSRange(location: loc, length: min(selection.length, text.length - loc))
        var reveal = text.paragraphRange(for: selection)
        for span in marks {
            guard case .codeBlock = span.kind else { continue }
            let block = text.paragraphRange(for: NSRange(location: Int(span.utf16Start), length: Int(span.utf16Len)))
            if NSIntersectionRange(block, reveal).length > 0 { reveal = NSUnionRange(reveal, block) }
        }
        return reveal
    }

    /// Styles by attributes only: the string, the selection and any input
    /// method's marked text are never touched. While marked text exists
    /// nothing is applied; the change after the input method commits
    /// restyles. `reveal` is where Markdown marks show (nil: nowhere). `range`
    /// limits the work (nil: all text). Returns whether it styled.
    @discardableResult
    static func restyle(
        _ view: NSTextView, tags: [TagRange], marks: [MarkdownSpan], reveal: NSRange?,
        palette: Palette, in range: NSRange? = nil
    ) -> Bool {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return false }
        let text = storage.string as NSString
        let target = NSIntersectionRange(range ?? NSRange(location: 0, length: text.length), NSRange(location: 0, length: text.length))
        let basePara = NSMutableParagraphStyle()
        basePara.lineSpacing = 4
        let bodyFont = font(size: EditorStyling.bodySize, weight: .regular, rounded: false)
        let body: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: palette.ink, .paragraphStyle: basePara]
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let titleFont = font(size: EditorStyling.titleSize, weight: .semibold, rounded: true)
        let tagFont = font(size: EditorStyling.bodySize, weight: .semibold, rounded: false)
        let spans = EditorStyling.spans(text: storage.string, tags: tags)
        let titles = spans.filter { $0.kind == .title }.map(\.range)

        func apply(_ attrs: [NSAttributedString.Key: Any], _ r: NSRange) {
            let r = NSIntersectionRange(r, target)
            if r.length > 0 { storage.addAttributes(attrs, range: r) }
        }
        func addTrait(_ trait: NSFontTraitMask, _ r: NSRange) {
            let r = NSIntersectionRange(r, target)
            guard r.length > 0 else { return }
            storage.enumerateAttribute(.font, in: r) { value, run, _ in
                let font = value as? NSFont ?? bodyFont
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: run)
            }
        }
        func paragraph(_ r: NSRange, _ configure: (NSMutableParagraphStyle) -> Void) {
            let style = basePara.mutableCopy() as! NSMutableParagraphStyle
            configure(style)
            apply([.paragraphStyle: style], text.paragraphRange(for: r))
        }
        func shown(_ r: NSRange) -> Bool { reveal.map { NSIntersectionRange($0, r).length > 0 } ?? false }

        let marks = marks.compactMap { span -> (kind: MarkdownKind, range: NSRange)? in
            let r = NSRange(location: Int(span.utf16Start), length: Int(span.utf16Len))
            let clamped = NSIntersectionRange(r, NSRange(location: 0, length: text.length))
            return clamped.length > 0 ? (span.kind, clamped) : nil
        }
        storage.beginEditing()
        storage.setAttributes(body, range: target)
        // Blocks first, then the title and tags over them, inline styling on top, hidden marks last.
        for (kind, r) in marks {
            switch kind {
            case .heading(let level):
                apply([.font: level == 1 ? font(size: 19, weight: .semibold, rounded: true) : font(size: 15.5, weight: .semibold, rounded: false)], r)
            case .bullet:
                apply([.foregroundColor: NSColor.clear, .noteDecoration: NoteDecoration.bullet.rawValue], r)
            case .taskBox(let checked):
                apply([.foregroundColor: NSColor.clear, .noteDecoration: (checked ? NoteDecoration.taskDone : .taskOpen).rawValue], r)
            case .number:
                apply([.foregroundColor: palette.rust, .font: font(size: EditorStyling.bodySize, weight: .semibold, rounded: false)], r)
            case .taskDone:
                apply([.foregroundColor: palette.bark, .strikethroughStyle: NSUnderlineStyle.single.rawValue], r)
            case .quote:
                paragraph(r) { $0.firstLineHeadIndent = 14; $0.headIndent = 14 }
                apply([.foregroundColor: palette.bark, .noteDecoration: NoteDecoration.quote.rawValue], r)
            case .codeBlock:
                paragraph(r) { $0.firstLineHeadIndent = 12; $0.headIndent = 12 }
                apply([.font: mono, .foregroundColor: palette.ink, .noteDecoration: NoteDecoration.codeBlock.rawValue], r)
            case .divider:
                apply([.noteDecoration: NoteDecoration.divider.rawValue, .foregroundColor: shown(r) ? palette.marker : NSColor.clear], r)
            default: break
            }
        }
        for range in titles { apply([.font: titleFont], range) }
        for span in spans where span.kind == .tag {
            let inTitle = titles.contains { NSIntersectionRange($0, span.range).length > 0 }
            apply([.foregroundColor: palette.rust, .font: inTitle ? titleFont : tagFont], span.range)
        }
        for (kind, r) in marks {
            switch kind {
            case .code:
                apply([.font: mono, .foregroundColor: palette.rust, .backgroundColor: palette.codeBackground], r)
            case .linkText:
                apply([.foregroundColor: palette.rust, .underlineStyle: NSUnderlineStyle.single.rawValue], r)
            case .strike:
                apply([.strikethroughStyle: NSUnderlineStyle.single.rawValue], r)
            case .bold: addTrait(.boldFontMask, r)
            case .italic: addTrait(.italicFontMask, r)
            default: break
            }
        }
        for (kind, r) in marks {
            switch kind {
            case .marker:
                if shown(r) { apply([.foregroundColor: palette.marker], r) } else { apply([.font: hiddenFont, .foregroundColor: NSColor.clear], r) }
            case .codeFence:
                if shown(r) {
                    apply([.font: mono, .foregroundColor: palette.marker], r)
                } else {
                    apply([.font: hiddenFont, .foregroundColor: NSColor.clear], r)
                    paragraph(r) {
                        $0.minimumLineHeight = 0.01
                        $0.maximumLineHeight = 0.01
                        $0.lineSpacing = 0
                        $0.paragraphSpacing = 0
                    }
                }
            default: break
            }
        }
        // Last, so the indent counts hidden marks as ~0 and a semibold number at its real width.
        for (kind, r) in marks {
            guard case .listContent = kind else { continue }
            let start = text.paragraphRange(for: r).location
            let indent = storage.attributedSubstring(from: NSRange(location: start, length: r.location - start)).size().width
            paragraph(r) { $0.headIndent = indent }
        }
        storage.endEditing()
        view.typingAttributes = body
        return true
    }
}
