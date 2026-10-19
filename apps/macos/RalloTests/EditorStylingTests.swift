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
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: text), marks: [], reveal: nil, pair: nil, palette: palette))
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
        NoteTextStyler.restyle(view, tags: tagRanges(text: text), marks: [], reveal: nil, pair: nil, palette: palette)
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
        XCTAssertFalse(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), marks: [], reveal: nil, pair: nil, palette: palette))
        XCTAssertEqual(view.string, before)
        XCTAssertTrue(view.hasMarkedText(), "restyling must not end the composition")
        view.unmarkText()
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), marks: [], reveal: nil, pair: nil, palette: palette))
        withExtendedLifetime(window) {}
    }

    // MARK: Markdown marks

    /// Styles `text`; `revealAll` shows every mark (the way a revealed link shows its own).
    private func styled(_ text: String, revealAll: Bool = false) -> (PlainTextView, NSWindow) {
        let (view, window) = textView(text)
        let reveal = revealAll ? NSRange(location: 0, length: (text as NSString).length) : nil
        NoteTextStyler.restyle(view, tags: [], marks: markdownSpans(text: text), reveal: reveal, pair: nil, palette: palette)
        return (view, window)
    }

    private func font(_ view: PlainTextView, _ index: Int) -> NSFont {
        view.textStorage!.attribute(.font, at: index, effectiveRange: nil) as! NSFont
    }

    private func color(_ view: PlainTextView, _ index: Int) -> NSColor {
        view.textStorage!.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor
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
        let (hidden, w1) = styled(text)
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

    func testLinkRevealCoversTheLinkWhileTheCaretIsStrictlyInside() {
        let text = "see [site](http://x.y) now", marks = markdownSpans(text: text)
        func reveal(_ loc: Int, _ len: Int = 0) -> NSRange? {
            NoteTextStyler.linkReveal(in: text as NSString, selection: NSRange(location: loc, length: len), marks: marks)
        }
        let link = NSRange(location: 4, length: 18)
        XCTAssertNil(reveal(4))
        XCTAssertEqual(reveal(5), link)
        XCTAssertEqual(reveal(21), link)
        XCTAssertNil(reveal(22))
        XCTAssertEqual(reveal(0, 5), link, "a range touching the link reveals it")
        XCTAssertNil(reveal(0, 4))
        XCTAssertNil(NoteTextStyler.linkReveal(in: "a **b** c" as NSString, selection: NSRange(location: 4, length: 0), marks: markdownSpans(text: "a **b** c")))
    }

    func testCaretInsideACodeBlockKeepsItsFencesHidden() {
        let text = "a\n```\ncode\n```\nb"
        let (view, window) = styled(text)
        view.setSelectedRange(range(of: "code", in: text))
        XCTAssertEqual(font(view, 2).pointSize, 0.01)
        XCTAssertEqual(font(view, 11).pointSize, 0.01)
        withExtendedLifetime(window) {}
    }

    func testBoldMarksStayHiddenWithTheCaretAnywhere() {
        let text = "x**bold**y"
        let (view, window) = styled(text)
        for caret in 0...10 {
            view.setSelectedRange(NSRange(location: caret, length: 0))
            for i in [1, 2, 7, 8] { XCTAssertEqual(font(view, i).pointSize, 0.01, "caret \(caret), index \(i)") }
        }
        withExtendedLifetime(window) {}
    }

    func testAPairIsHiddenByFontAndColour() {
        let text = "a****"
        let (view, window) = textView(text)
        NoteTextStyler.restyle(view, tags: [], marks: [], reveal: nil, pair: NSRange(location: 1, length: 4), palette: palette)
        for i in 1..<5 {
            XCTAssertEqual(font(view, i).pointSize, 0.01)
            XCTAssertEqual(color(view, i), .clear)
        }
        withExtendedLifetime(window) {}
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

    func testABlockOnTheTitleLineKeepsItsOwnFont() {
        let (view, window) = styled("- [ ] buy\nmilk")
        XCTAssertEqual(font(view, 8).pointSize, EditorStyling.bodySize)
        let (heading, w2) = styled("# Plan\nmilk")
        XCTAssertEqual(font(heading, 3).pointSize, EditorStyling.titleSize)
        withExtendedLifetime((window, w2)) {}
    }

    func testATagInAHeadingTakesTheHeadingSize() {
        let text = "# Release #v2"
        let (view, window) = textView(text)
        NoteTextStyler.restyle(view, tags: tagRanges(text: text), marks: markdownSpans(text: text), reveal: nil, pair: nil, palette: palette)
        let heading = font(view, 3).pointSize
        XCTAssertGreaterThan(heading, EditorStyling.bodySize)
        XCTAssertEqual(font(view, 10).pointSize, heading)
        withExtendedLifetime(window) {}
    }

    func testARangeRestyleDoesNotTouchListLinesOutsideIt() {
        let text = "a **b**\n- one\n- two"
        let (view, window) = styled(text)
        let sentinel = NSMutableParagraphStyle()
        sentinel.headIndent = 999
        view.textStorage!.addAttribute(.paragraphStyle, value: sentinel, range: NSRange(location: 8, length: 11))
        NoteTextStyler.restyle(view, tags: [], marks: view.marks.isEmpty ? markdownSpans(text: text) : view.marks, reveal: nil, pair: nil,
                               palette: palette, in: NSRange(location: 0, length: 8))
        let style = view.textStorage!.attribute(.paragraphStyle, at: 10, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(style.headIndent, 999)
        withExtendedLifetime(window) {}
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
    /// Link 1 spans 2..<9 (`[` at 2, `]` at 5); link 2 spans 12..<19.
    private let text = "a [bc](u)\nc [de](v)"
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

    private func visible(_ index: Int) -> Bool {
        (view.textStorage!.attribute(.font, at: index, effectiveRange: nil) as! NSFont).pointSize > 1
    }

    private func move(to location: Int) {
        view.setSelectedRange(NSRange(location: location, length: 0))
        coordinator.updateReveal(view)
    }

    func testALinkRevealsWhileTheCaretIsInsideAndBumpsLayoutRevisionOnlyOnChange() {
        XCTAssertFalse(visible(2))
        XCTAssertFalse(visible(12))
        let before = session.layoutRevision
        move(to: 4)
        XCTAssertTrue(visible(2))
        XCTAssertTrue(visible(5))
        XCTAssertFalse(visible(12))
        XCTAssertEqual(session.layoutRevision, before + 1)
        move(to: 7)
        XCTAssertEqual(session.layoutRevision, before + 1)
        move(to: 14)
        XCTAssertFalse(visible(2))
        XCTAssertTrue(visible(12))
        XCTAssertEqual(session.layoutRevision, before + 2)
    }

    func testRangeRestyleLeavesOtherLinesAlone() {
        move(to: 4)
        let font = view.textStorage!.attribute(.font, at: 2, effectiveRange: nil)
        let palette = NoteTextStyler.Palette(ink: .black, rust: .red)
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: [], marks: view.marks, reveal: nil, pair: nil, palette: palette, in: NSRange(location: 10, length: 9)))
        XCTAssertEqual(view.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as? NSFont, font as? NSFont)
        XCTAssertTrue(visible(2))
    }

    func testMovingBetweenLinesWithoutLinksDoesNotRestyle() {
        let plain = "one **x**\ntwo"
        view.string = plain
        coordinator.restyle(view)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.updateReveal(view)
        let before = session.layoutRevision
        move(to: 12)
        XCTAssertEqual(session.layoutRevision, before)
    }

    func testMarkedTextBlocksReveal() {
        move(to: 4)
        let before = session.layoutRevision
        view.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 10, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        coordinator.updateReveal(view)
        XCTAssertEqual(session.layoutRevision, before)
        XCTAssertTrue(visible(2))
    }

    func testAnExternalReplaceRevealsTheLinkTheCaretIsIn() {
        view.string = text
        view.setSelectedRange(NSRange(location: 14, length: 0))
        coordinator.restyle(view)
        XCTAssertTrue(visible(12))
        XCTAssertFalse(visible(2))
    }

    /// Pins: a keystroke inside a revealed link leaves `layoutRevision` as the full restyle does (no bump),
    /// and the marks stay revealed.
    func testTypingDoesNotRestyleWithStaleMarks() {
        view.delegate = coordinator
        view.setSelectedRange(NSRange(location: 4, length: 0))
        coordinator.restyle(view)
        let before = session.layoutRevision
        view.insertText("x", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "a [bxc](u)\nc [de](v)")
        XCTAssertEqual(session.layoutRevision, before)
        XCTAssertTrue(visible(2))
        XCTAssertFalse(visible(13))
    }

    func testLosingFocusHidesEverything() {
        move(to: 4)
        XCTAssertTrue(visible(2))
        window.makeFirstResponder(nil)
        XCTAssertFalse(visible(2))
    }
}
