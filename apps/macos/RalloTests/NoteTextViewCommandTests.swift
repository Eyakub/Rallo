import XCTest

@MainActor
final class NoteTextViewCommandTests: XCTestCase {
    private var window: NSWindow?

    private func makeView(_ text: String, _ sel: NSRange) -> PlainTextView {
        let view = PlainTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let win = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = view
        win.makeFirstResponder(view)
        window = win
        view.string = text
        view.marks = markdownSpans(text: text)
        view.setSelectedRange(sel)
        return view
    }

    func testBoldActionWrapsTheSelectionAndOneUndoRestoresIt() {
        let view = makeView("Ship rich text", NSRange(location: 5, length: 4))
        view.formatBold(nil)
        XCTAssertEqual(view.string, "Ship **rich** text")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "Ship rich text")
    }

    func testActionsDoNothingWhileComposing() {
        let view = makeView("Ship", NSRange(location: 4, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 4, length: 0))
        let before = view.string
        view.formatBold(nil)
        XCTAssertEqual(view.string, before)
    }

    func testReturnContinuesAList() {
        let view = makeView("- one", NSRange(location: 5, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- one\n- ")
    }

    func testMenuValidationChecksBold() {
        let view = makeView("a **b** c", NSRange(location: 5, length: 0))
        let item = NSMenuItem(title: "Bold", action: #selector(PlainTextView.formatBold(_:)), keyEquivalent: "b")
        XCTAssertTrue(view.validateUserInterfaceItem(item))
        XCTAssertEqual(item.state, .on)
    }
}
