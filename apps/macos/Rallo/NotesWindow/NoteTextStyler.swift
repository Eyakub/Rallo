import AppKit

/// The editor's text view: plain text only. Paste drops fonts, colours and attachments.
final class PlainTextView: NSTextView {
    /// TextKit 1 (the editor measures with its layout manager), plain text, no
    /// smart quotes or dashes rewriting what the user typed.
    static func make() -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: false)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
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
    }

    static func font(size: CGFloat, weight: NSFont.Weight, rounded: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Styles by attributes only: the string, the selection and any input
    /// method's marked text are never touched. While marked text exists
    /// nothing is applied; the change after the input method commits
    /// restyles. Returns whether it styled.
    @discardableResult
    static func restyle(_ view: NSTextView, tags: [TagRange], palette: Palette) -> Bool {
        guard !view.hasMarkedText(), let storage = view.textStorage else { return false }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: font(size: EditorStyling.bodySize, weight: .regular, rounded: false),
            .foregroundColor: palette.ink,
            .paragraphStyle: paragraph,
        ]
        let titleFont = font(size: EditorStyling.titleSize, weight: .semibold, rounded: true)
        let tagFont = font(size: EditorStyling.bodySize, weight: .semibold, rounded: false)
        let spans = EditorStyling.spans(text: storage.string, tags: tags)
        let titles = spans.filter { $0.kind == .title }.map(\.range)
        storage.beginEditing()
        storage.setAttributes(body, range: NSRange(location: 0, length: storage.length))
        for range in titles {
            storage.addAttribute(.font, value: titleFont, range: range)
        }
        for span in spans where span.kind == .tag {
            let inTitle = titles.contains { NSIntersectionRange($0, span.range).length > 0 }
            storage.addAttributes([.foregroundColor: palette.rust, .font: inTitle ? titleFont : tagFont], range: span.range)
        }
        storage.endEditing()
        view.typingAttributes = body
        return true
    }
}
