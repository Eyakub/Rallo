import XCTest

/// A test window can't become key headless; this one says so on demand.
private final class StubKeyWindow: NSWindow {
    var stubKey = false
    override var isKeyWindow: Bool { stubKey }
}

@MainActor
final class NoteTextViewCommandTests: XCTestCase {
    private var window: NSWindow?

    private func makeView(_ text: String, _ sel: NSRange) -> PlainTextView {
        let view = PlainTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let win = StubKeyWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = view
        win.makeFirstResponder(view)
        window = win
        view.string = text
        view.marks = markdownSpans(text: text)
        view.setSelectedRange(sel)
        return view
    }

    private func boxCenter(_ view: PlainTextView) -> NSPoint {
        let layout = view.layoutManager as! NoteLayoutManager
        layout.ensureLayout(for: view.textContainer!)
        let span = view.marks.first { if case .taskBox = $0.kind { return true } else { return false } }!
        let rect = layout.boxRect(forCharacterRange: NSRange(location: Int(span.utf16Start), length: Int(span.utf16Len)))!
        let o = view.textContainerOrigin
        return NSPoint(x: rect.midX + o.x, y: rect.midY + o.y)
    }

    private func click(_ view: PlainTextView, at p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testClickingATaskBoxTogglesItAndKeepsTheSelection() {
        let view = makeView("- [ ] task\n- [x] done", NSRange(location: 14, length: 2))
        let palette = NoteTextStyler.Palette(ink: .black, rust: .red)
        NoteTextStyler.restyle(view, tags: [], marks: view.marks, reveal: nil, pair: nil, palette: palette)
        let p = boxCenter(view)
        XCTAssertTrue(view.handleMouseDown(click(view, at: NSPoint(x: p.x + 40, y: p.y))) == false)
        XCTAssertEqual(view.string, "- [ ] task\n- [x] done")
        view.mouseDown(with: click(view, at: p))
        XCTAssertEqual(view.string, "- [x] task\n- [x] done")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 14, length: 2))
    }

    func testBoldActionWrapsTheSelectionAndOneUndoRestoresIt() {
        let view = makeView("Ship rich text", NSRange(location: 5, length: 4))
        view.formatBold(nil)
        XCTAssertEqual(view.string, "Ship **rich** text")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "Ship rich text")
    }

    func testFormatActionsAreOffWhileTheWindowIsNotKey() {
        let view = makeView("a **b** c", NSRange(location: 5, length: 0))
        XCTAssertFalse(window!.isKeyWindow)
        let item = NSMenuItem(title: "Bold", action: #selector(PlainTextView.formatBold(_:)), keyEquivalent: "b")
        XCTAssertFalse(view.validateUserInterfaceItem(item))
    }

    func testBodyInsideACodeBlockRemovesTheFences() {
        let view = makeView("```\ncode\n```", NSRange(location: 5, length: 0))
        view.formatBody(nil)
        XCTAssertEqual(view.string, "code")
    }

    func testActionsDoNothingWhileComposing() {
        let view = makeView("Ship", NSRange(location: 4, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
        let before = view.string
        view.formatBold(nil)
        XCTAssertEqual(view.string, before)
    }

    func testBodyIsCurrentOnlyOnPlainLines() {
        XCTAssertFalse(makeView("- a", NSRange(location: 3, length: 0)).isActive(#selector(PlainTextView.formatBody(_:))))
        XCTAssertTrue(makeView("a", NSRange(location: 1, length: 0)).isActive(#selector(PlainTextView.formatBody(_:))))
    }

    func testMonostyledIsCurrentInsideACodeBlock() {
        let view = makeView("```\ncode\n```", NSRange(location: 5, length: 0))
        XCTAssertTrue(view.isActive(#selector(PlainTextView.formatMonostyled(_:))))
        XCTAssertFalse(view.isActive(#selector(PlainTextView.formatBody(_:))))
    }

    func testReturnContinuesAList() {
        let view = makeView("- one", NSRange(location: 5, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- one\n- ")
    }

    func testMenuValidationChecksBold() {
        let view = makeView("a **b** c", NSRange(location: 5, length: 0))
        (window as! StubKeyWindow).stubKey = true
        let item = NSMenuItem(title: "Bold", action: #selector(PlainTextView.formatBold(_:)), keyEquivalent: "b")
        XCTAssertTrue(view.validateUserInterfaceItem(item))
        XCTAssertEqual(item.state, .on)
    }

    // MARK: Hidden marks (caret and edit rules)

    private var session: NoteEditorSession?
    private var coordinator: NoteTextEditor.Coordinator?

    /// `makeView` plus the editor's Coordinator as delegate: snapping, restyling and the hidden pair work as in the app.
    private func wired(_ text: String, _ sel: NSRange) -> PlainTextView {
        let view = makeView(text, NSRange(location: 0, length: 0))
        let session = NoteEditorSession(core: CoreClient(dataDir: NSTemporaryDirectory() + "rallo-unused"))
        let coordinator = NoteTextEditor.Coordinator(session: session)
        coordinator.attach(view)
        view.delegate = coordinator
        coordinator.restyle(view)
        self.session = session
        self.coordinator = coordinator
        view.setSelectedRange(sel)
        return view
    }

    private func r(_ l: Int, _ n: Int = 0) -> NSRange { NSRange(location: l, length: n) }

    private func runMainQueue() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testProgrammaticSelectionSnapsOutOfAHiddenMark() {
        let view = wired("x**bold**y", r(0))
        view.setSelectedRange(r(2))
        XCTAssertEqual(view.selectedRange(), r(1))
        view.setSelectedRange(r(8))
        XCTAssertEqual(view.selectedRange(), r(9))
    }

    func testTypingInsideAnEmptyPairKeepsTheCaretBeforeTheHiddenCloser() {
        let view = wired("", r(0))
        view.formatBold(nil)
        XCTAssertEqual(view.string, "****")
        view.insertText("a", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "**a**")
        XCTAssertEqual(view.selectedRange(), r(3), "the edit left the caret before the hidden closer")
        view.insertText("b", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "**ab**")
        XCTAssertEqual(view.selectedRange(), r(4))
        XCTAssertFalse(view.isEditingText)
        view.setSelectedRange(r(4))  // a plain move after the edit snaps again: to rest after the closer
        XCTAssertEqual(view.selectedRange(), r(6))
        view.setSelectedRange(r(5))  // one step left from the rest position hops over the closer
        XCTAssertEqual(view.selectedRange(), r(3))
    }

    // MARK: Editing rules

    private func backspace(_ text: String, _ sel: NSRange) -> PlainTextView {
        let view = makeView(text, sel)
        view.deleteBackward(nil)
        return view
    }

    func testBackspaceAfterAClosingMarkDeletesTheCharBeforeIt() {
        XCTAssertEqual(backspace("x**bold**y", r(9)).string, "x**bol**y")
        XCTAssertEqual(backspace("**a**", r(5)).string, "")
        XCTAssertEqual(backspace("x**a**y", r(2)).string, "**a**y", "inside the opener: the char before it")
    }

    func testBackspaceIsOneUndoStep() {
        let view = backspace("x**bold**y", r(9))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "x**bold**y")
    }

    func testForwardDeleteBeforeAnOpeningMarkDeletesTheCharAfterIt() {
        let view = makeView("x**a**y", r(1))
        view.deleteForward(nil)
        XCTAssertEqual(view.string, "xy")
        let bold = makeView("x**bold**y", r(1))
        bold.deleteForward(nil)
        XCTAssertEqual(bold.string, "x**old**y")
        let atEnd = makeView("a**b**", r(1))
        atEnd.deleteForward(nil)
        XCTAssertEqual(atEnd.string, "a")
    }

    func testBackspaceAtAHeadingsContentStartRemovesTheHeading() {
        XCTAssertEqual(backspace("# Title", r(2)).string, "Title")
        XCTAssertEqual(backspace("> quote", r(2)).string, "quote")
        XCTAssertEqual(backspace("- one\n- two", r(8)).string, "- one\ntwo")
    }

    func testBackspaceAtATaskContentStartRunsTheBodyCommand() {
        XCTAssertEqual(backspace("- [ ] task", r(6)).string, "task")
    }

    func testBackspaceAfterADividerDeletesIt() {
        XCTAssertEqual(backspace("a\n---\nb", r(6)).string, "a\nb")
        XCTAssertEqual(backspace("a\n---", r(5)).string, "a")
    }

    func testBackspaceAfterTheOpeningFenceRemovesBothFences() {
        XCTAssertEqual(backspace("a\n```\nx\n```", r(6)).string, "a\nx")
    }

    func testBackspaceAfterTheClosingFenceOnlyMovesTheCaret() {
        let text = "```\nx\n```\nb"
        let view = backspace(text, r(10))
        XCTAssertEqual(view.string, text)
        XCTAssertEqual(view.selectedRange(), r(5))
    }

    func testForwardDeleteBeforeADividerDeletesItAndBeforeAFenceDoesNothing() {
        let div = makeView("a\n---\nb", r(1))
        div.deleteForward(nil)
        XCTAssertEqual(div.string, "a\nb")
        let fence = makeView("a\n```\nx\n```", r(1))
        fence.deleteForward(nil)
        XCTAssertEqual(fence.string, "a\n```\nx\n```")
    }

    func testDeletingTheOnlyCharOfASpanDeletesTheWholeSpan() {
        XCTAssertEqual(backspace("a *b* c", r(4)).string, "a  c", "caret after the b, in front of the closer")
        XCTAssertEqual(backspace("see [x](http://u) now", r(6)).string, "see  now")
        XCTAssertEqual(backspace("p `c`", r(4)).string, "p ")
    }

    func testDeletingASelectedWordTakesItsMarks() {
        let view = makeView("x**bold**y", r(3, 4))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "xy")
    }

    func testPartnerRuleRemovesTheOtherMark() {
        let view = makeView("x**bold** y", r(5, 6))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "xbo")
        let forward = makeView("x**bold** y", r(0, 5))
        forward.deleteForward(nil)
        XCTAssertEqual(forward.string, "ld y")
    }

    func testTypingOverASelectedWordKeepsItsMarks() {
        let view = makeView("x**bold**y", r(3, 4))
        view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "x**z**y")
        XCTAssertEqual(view.selectedRange(), r(4))
    }

    func testTypingOverAPartOfSpanTakesTheOtherMark() {
        let view = makeView("x**bold** y", r(5, 6))
        view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "xboz")
    }

    func testCutCopiesTheSelectionAndRemovesItsMarks() {
        let view = makeView("x**bold**y", r(3, 4))
        NSPasteboard.general.clearContents()
        view.cut(nil)
        XCTAssertEqual(view.string, "xy")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "bold")
    }

    func testTypingOnAnEndingFenceLineStartsANewLine() {
        let view = makeView("```\nx\n```", r(9))
        view.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "```\nx\n```\ny")
        XCTAssertEqual(view.selectedRange(), r(11))
    }

    func testBoldOnAnEmptySelectionHidesItsPairUntilTheCaretLeaves() {
        let view = wired("a", r(1))
        view.formatBold(nil)
        XCTAssertEqual(view.string, "a****")
        XCTAssertEqual(view.selectedRange(), r(3))
        for i in 1..<5 {
            XCTAssertEqual((view.textStorage!.attribute(.font, at: i, effectiveRange: nil) as! NSFont).pointSize, 0.01, "index \(i)")
        }
        view.setSelectedRange(r(0))
        runMainQueue()
        XCTAssertEqual(view.string, "a")
        XCTAssertEqual(view.selectedRange(), r(0))
    }

    func testBoldTwiceOnAnEmptySelectionRemovesThePair() {
        let view = wired("a", r(1))
        view.formatBold(nil)
        view.formatBold(nil)
        XCTAssertEqual(view.string, "a")
        XCTAssertNil(view.pendingPair)
    }

    func testBackspaceOnAnEmptyPairRemovesItWhole() {
        let view = wired("a", r(1))
        view.formatItalic(nil)
        XCTAssertEqual(view.string, "a**")
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "a")
    }

    func testTypingInTheHiddenPairMakesItReal() {
        let view = wired("a", r(1))
        view.formatBold(nil)
        view.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "a**b**")
        view.setSelectedRange(r(0))
        runMainQueue()
        XCTAssertEqual(view.string, "a**b**")
        XCTAssertNil(view.pendingPair)
    }
}
