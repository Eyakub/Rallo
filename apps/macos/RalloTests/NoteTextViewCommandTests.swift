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
        NoteTextStyler.restyle(view, tags: [], marks: view.marks, reveal: nil, palette: palette)
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
}
