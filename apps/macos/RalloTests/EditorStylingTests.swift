import AppKit
import XCTest

final class EditorStylingTests: XCTestCase {
    private let palette = NoteTextStyler.Palette(ink: .black, rust: .red)

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle, options: .literal)
    }

    private func tagSpans(_ spans: [EditorSpan]) -> [NSRange] { spans.filter { $0.kind == .tag }.map(\.range) }

    // MARK: Title range

    func testTheTitleIsTheFirstLineOrTheTextBeforeAColonAndSpace() {
        XCTAssertEqual(EditorStyling.titleRange(in: "Ledger audit logs\nStore who changed what"), NSRange(location: 0, length: 17))
        XCTAssertEqual(EditorStyling.titleRange(in: "Plan: ship it"), NSRange(location: 0, length: 4))
        XCTAssertEqual(EditorStyling.titleRange(in: "  \n Plan\nbody"), range(of: "Plan", in: "  \n Plan\nbody"))
        XCTAssertNil(EditorStyling.titleRange(in: "No title here"))
        XCTAssertNil(EditorStyling.titleRange(in: ""))
    }

    func testTheTitleRangeCountsUTF16ForBanglaAndEmoji() {
        let bangla = "কাজ: #কাজ করো 🦊 #bug-"
        XCTAssertEqual(EditorStyling.titleRange(in: bangla), NSRange(location: 0, length: 3), "ক া জ are three UTF-16 units")
        let emoji = "🦊 fox\nbody"
        XCTAssertEqual(EditorStyling.titleRange(in: emoji), NSRange(location: 0, length: 6), "the fox is a surrogate pair")
    }

    func testACRLFLineBreakEndsTheTitleAtTheRightPlace() {
        let text = "Plan\r\n#bug later\r\nmore"
        XCTAssertEqual(EditorStyling.titleRange(in: text), NSRange(location: 0, length: 4))
        let spans = EditorStyling.spans(text: text, tags: tagRanges(text: text))
        XCTAssertEqual(tagSpans(spans), [range(of: "#bug", in: text)])
        XCTAssertEqual(range(of: "#bug", in: text).location, 6, "\r\n is two UTF-16 units")
    }

    // MARK: Tags, from the core's ranges

    func testBanglaEmojiAndATrailingHyphenTag() {
        let text = "কাজ: #কাজ করো 🦊 #bug-"
        let spans = EditorStyling.spans(text: text, tags: tagRanges(text: text))
        XCTAssertEqual(tagSpans(spans), [range(of: "#কাজ", in: text), range(of: "#bug", in: text)])
        XCTAssertEqual(spans.first?.kind, .title)
    }

    func testATagAfterAnEmojiAndSpace() {
        let text = "🦊 #fox and C# and https://x.y/#frag"
        let spans = EditorStyling.spans(text: text, tags: tagRanges(text: text))
        XCTAssertEqual(tagSpans(spans), [range(of: "#fox", in: text)], "C# and a URL fragment are not tags")
    }

    func testStaleRangesPastTheEndAreDropped() {
        let stale = TagRange(utf16Start: 2, utf16Len: 40, name: "x")
        XCTAssertTrue(tagSpans(EditorStyling.spans(text: "ab #x", tags: [stale])).isEmpty)
    }

    // MARK: List text

    func testRowTextShowsPlainTextButTitleRangeStaysRaw() {
        let row = RowText("# Plan\n**ship** it")
        XCTAssertEqual(row.title, "Plan")
        XCTAssertEqual(row.preview, "ship it")
        let range = EditorStyling.titleRange(in: "# Plan\nbody")
        XCTAssertEqual(range?.location, 0)
        XCTAssertEqual(range?.length, 6)
    }

    func testRowTextIsTheTitleAndWhatFollows() {
        XCTAssertEqual(RowText("Standup\nWhat changed\nsince Friday").title, "Standup")
        XCTAssertEqual(RowText("Standup\nWhat changed\nsince Friday").preview, "What changed since Friday")
        XCTAssertEqual(RowText("Call the dentist").title, "Call the dentist")
        XCTAssertEqual(RowText("Call the dentist").preview, "")
        XCTAssertEqual(RowText("One line that is long enough to be a body but has two\nparts here").title, "One line that is long enough to be a body but has two")
    }

    func testAnImageOnlyNoteIsCalledImage() {
        XCTAssertEqual(RowText("").displayTitle, "Image")
        XCTAssertEqual(RowText("  \n ").displayTitle, "Image")
    }

    // MARK: Attributes

    private func textView(_ text: String) -> (PlainTextView, NSWindow) {
        let view = PlainTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view  // an offscreen window, so input methods have somewhere to live
        view.string = text
        return (view, window)
    }

    func testTitleAndTagAttributes() {
        let text = "Plan: ship #bug today"
        let (view, window) = textView(text)
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: text), marks: [], reveal: nil, palette: palette))
        let storage = view.textStorage!
        func font(at index: Int) -> NSFont { storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont }
        func color(at index: Int) -> NSColor { storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor }
        XCTAssertEqual(font(at: 0).pointSize, 24)
        XCTAssertEqual(color(at: 0), .black)
        XCTAssertEqual(font(at: 8).pointSize, 14.5)  // "ship"
        let tag = (text as NSString).range(of: "#bug").location
        XCTAssertEqual(color(at: tag), .red)
        XCTAssertEqual(font(at: tag).pointSize, 14.5)
        XCTAssertEqual(color(at: tag + 4), .black)
        XCTAssertEqual(view.string, text)
        withExtendedLifetime(window) {}
    }

    func testATagInsideTheTitleKeepsTheTitleSize() {
        let text = "Fix #bug\nlater"
        let (view, window) = textView(text)
        NoteTextStyler.restyle(view, tags: tagRanges(text: text), marks: [], reveal: nil, palette: palette)
        let font = view.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as! NSFont
        XCTAssertEqual(font.pointSize, 24)
        XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .red)
        withExtendedLifetime(window) {}
    }

    /// Review focus 1: an input method's composition must survive restyling.
    func testRestyleLeavesMarkedTextAlone() {
        let (view, window) = textView("#bug ")
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 1), replacementRange: NSRange(location: 5, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let before = view.string
        XCTAssertFalse(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), marks: [], reveal: nil, palette: palette))
        XCTAssertEqual(view.string, before)
        XCTAssertTrue(view.hasMarkedText(), "restyling must not end the composition")
        view.unmarkText()
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), marks: [], reveal: nil, palette: palette))
        withExtendedLifetime(window) {}
    }

    // MARK: Markdown marks

    /// Styles `text` with `reveal` given as the paragraph of `revealAt` (nil: nowhere).
    private func styled(_ text: String, revealAt: String? = nil, revealAll: Bool = false) -> (PlainTextView, NSWindow) {
        let (view, window) = textView(text)
        let marks = markdownSpans(text: text)
        var reveal: NSRange?
        if revealAll {
            reveal = NSRange(location: 0, length: (text as NSString).length)
        } else if let revealAt {
            reveal = NoteTextStyler.revealRange(in: text as NSString, selection: range(of: revealAt, in: text), marks: marks)
        }
        NoteTextStyler.restyle(view, tags: [], marks: marks, reveal: reveal, palette: palette)
        return (view, window)
    }

    private func font(_ view: PlainTextView, _ index: Int) -> NSFont {
        view.textStorage!.attribute(.font, at: index, effectiveRange: nil) as! NSFont
    }

    private func color(_ view: PlainTextView, _ index: Int) -> NSColor {
        view.textStorage!.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor
    }

    func testMarkersOffTheRevealedLineAreHidden() {
        let text = "Plan\nShip **rich** text\nmore **x**"
        let (view, window) = styled(text, revealAt: "Ship")
        let line3 = range(of: "**x", in: text).location
        XCTAssertEqual(font(view, line3).pointSize, 0.01)
        XCTAssertEqual(color(view, line3), .clear)
        let line2 = range(of: "**rich", in: text).location
        XCTAssertEqual(font(view, line2).pointSize, 14.5)
        XCTAssertEqual(color(view, line2), palette.marker)
        withExtendedLifetime(window) {}
    }

    func testNilRevealHidesEveryMarker() {
        let text = "Plan\nShip **rich** text\nmore **x**"
        let (view, window) = styled(text)
        for needle in ["**rich", "**x"] {
            let at = range(of: needle, in: text).location
            XCTAssertEqual(font(view, at).pointSize, 0.01)
            XCTAssertEqual(color(view, at), .clear)
        }
        withExtendedLifetime(window) {}
    }

    func testBoldAndItalicCarryTheirTraits() {
        let text = "x **b** *i*"
        let (view, window) = styled(text, revealAll: true)
        XCTAssertTrue(NSFontManager.shared.traits(of: font(view, range(of: "b", in: text).location)).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: font(view, range(of: "i", in: text).location)).contains(.italicFontMask))
        withExtendedLifetime(window) {}
    }

    func testHiddenFenceLinesCollapse() {
        let text = "a\n```\ncode\n```\nb"
        let (hidden, w1) = styled(text, revealAt: "a")
        let (shown, w2) = styled(text, revealAll: true)
        for fence in [2, 11] {
            let style = hidden.textStorage!.attribute(.paragraphStyle, at: fence, effectiveRange: nil) as! NSParagraphStyle
            XCTAssertEqual(style.maximumLineHeight, 0.01)
        }
        XCTAssertLessThan(
            NoteTextEditor.textHeight(hidden.textStorage!, width: 400),
            NoteTextEditor.textHeight(shown.textStorage!, width: 400) - 30)
        withExtendedLifetime((w1, w2)) {}
    }

    func testRevealRangeCoversTheWholeCodeBlock() {
        let text = "a\n```\ncode\n```\nb"
        let reveal = NoteTextStyler.revealRange(in: text as NSString, selection: range(of: "code", in: text), marks: markdownSpans(text: text))
        XCTAssertEqual(reveal, NSRange(location: 2, length: 13))  // "```\ncode\n```\n"
    }

    func testACaretAtTheTextEndRevealsItsOwnLine() {
        let text = "a\n**b**"
        let reveal = NoteTextStyler.revealRange(in: text as NSString, selection: NSRange(location: 7, length: 0), marks: markdownSpans(text: text))
        XCTAssertEqual(reveal, NSRange(location: 2, length: 5))
    }

    func testListIndentFollowsTheVisibleMarks() {
        let text = "- [ ] task"
        let body = NSFont.systemFont(ofSize: EditorStyling.bodySize)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: body]).width }
        func indent(_ view: PlainTextView) -> CGFloat {
            (view.textStorage!.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as! NSParagraphStyle).headIndent
        }
        let (hidden, w1) = styled(text)
        XCTAssertLessThan(indent(hidden), width("[ ] ") + 1)
        let (shown, w2) = styled(text, revealAll: true)
        XCTAssertGreaterThanOrEqual(indent(shown), width("- [ ] ") - 1)
        withExtendedLifetime((w1, w2)) {}
    }

    func testStylingNeverChangesTheString() {
        let text = "# H\n> q\n- [x] done *i*\n---\n```\ncode\n```"
        let (view, window) = styled(text)
        XCTAssertEqual(view.string, text)
        withExtendedLifetime(window) {}
    }

    func testThePlainTextViewIsPlainTextKitOne() {
        let (view, window) = textView("")
        XCTAssertFalse(view.isRichText)
        XCTAssertFalse(view.importsGraphics)
        XCTAssertNotNil(view.layoutManager, "TextKit 1: the editor measures its height with the layout manager")
        withExtendedLifetime(window) {}
    }
}

@MainActor
final class NoteTextEditorCommitTests: XCTestCase {
    /// An input method's word is committed into the current note before a switch.
    func testCommitCompositionPushesTheMarkedWordAndEndsComposing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = CoreClient(dataDir: dir.path)
        try await core.open()
        let session = NoteEditorSession(core: core, saveDelay: 0.05)
        session.show(.draft(folderID: nil, seed: ""))
        let coordinator = NoteTextEditor.Coordinator(session: session)
        let view = PlainTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.string = "abc "
        coordinator.attach(view)
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
        session.isComposing = true
        XCTAssertTrue(view.hasMarkedText())

        session.commitComposition()

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(view.string, "abc にほ")
        XCTAssertEqual(session.text, "abc にほ")
        withExtendedLifetime(window) {}
    }

    /// A focus request belongs to the shown target, so an editor mounted afterwards still honours it.
    func testAShowWithFocusAsksForFocusAndAPlainShowDoesNot() {
        let session = NoteEditorSession(core: CoreClient(dataDir: NSTemporaryDirectory() + "rallo-unused"))
        session.show(.draft(folderID: nil, seed: ""), focus: true)
        XCTAssertTrue(session.wantsFocus)
        session.show(.none)
        XCTAssertFalse(session.wantsFocus, "a re-created editor for a note shown without focus must not steal it")
    }

    func testCommitWithoutMarkedTextStillClearsComposingAndPushesText() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-commit2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let core = CoreClient(dataDir: dir.path)
        try await core.open()
        let session = NoteEditorSession(core: core, saveDelay: 0.05)
        session.show(.draft(folderID: nil, seed: ""))
        let coordinator = NoteTextEditor.Coordinator(session: session)
        let view = PlainTextView.make()
        view.string = "typed"
        session.isComposing = true
        coordinator.commitComposition(view)
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(session.text, "typed")
    }
}

@MainActor
final class NoteRevealTests: XCTestCase {
    private let text = "a **b**\nc **d**"
    private var window: NSWindow!
    private var view: PlainTextView!
    private var session: NoteEditorSession!
    private var coordinator: NoteTextEditor.Coordinator!

    override func setUp() {
        session = NoteEditorSession(core: CoreClient(dataDir: NSTemporaryDirectory() + "rallo-unused"))
        coordinator = NoteTextEditor.Coordinator(session: session)
        view = PlainTextView.make()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.string = text
        coordinator.attach(view)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyle(view)
    }

    /// The `**` of line 1 starts at 2, of line 2 at 10.
    private func visible(_ index: Int) -> Bool {
        (view.textStorage!.attribute(.font, at: index, effectiveRange: nil) as! NSFont).pointSize > 1
    }

    private func move(to location: Int) {
        view.setSelectedRange(NSRange(location: location, length: 0))
        coordinator.updateReveal(view)
    }

    func testRevealFollowsTheCaretAndBumpsLayoutRevisionOnlyOnChange() {
        XCTAssertTrue(visible(2))
        XCTAssertFalse(visible(10))
        let before = session.layoutRevision
        move(to: 9)
        XCTAssertFalse(visible(2))
        XCTAssertTrue(visible(10))
        XCTAssertEqual(session.layoutRevision, before + 1)
        move(to: 11)
        XCTAssertEqual(session.layoutRevision, before + 1)
    }

    func testRangeRestyleLeavesOtherLinesAlone() {
        let font = view.textStorage!.attribute(.font, at: 2, effectiveRange: nil)
        let palette = NoteTextStyler.Palette(ink: .black, rust: .red)
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: [], marks: view.marks, reveal: nil, palette: palette, in: NSRange(location: 8, length: 7)))
        XCTAssertEqual(view.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, font as? NSFont)
        XCTAssertTrue(visible(2))
    }

    func testMarkedTextBlocksReveal() {
        let before = session.layoutRevision
        view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 9, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        coordinator.updateReveal(view)  // the caret is now on line 2
        XCTAssertEqual(session.layoutRevision, before)
        XCTAssertTrue(visible(2))
    }

    func testAnExternalReplaceRevealsTheCaretsLine() {
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.string = text
        coordinator.restyle(view)
        XCTAssertTrue(visible(10))
        XCTAssertFalse(visible(2))
    }

    func testLosingFocusHidesEverything() {
        window.makeFirstResponder(nil)
        XCTAssertFalse(visible(2))
    }
}
