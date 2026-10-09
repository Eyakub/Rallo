import AppKit
import XCTest

@MainActor
final class NoteTextEditorSizingTests: XCTestCase {
    private func makeView() -> PlainTextView {
        let view = PlainTextView.make()
        let text = String(repeating: "word ", count: 120)
        view.string = text
        view.textStorage?.addAttribute(
            .font, value: NoteTextStyler.font(size: 15, weight: .regular, rounded: false),
            range: NSRange(location: 0, length: (text as NSString).length))
        return view
    }

    func testNarrowWidthWrapsMoreThanWide() throws {
        let view = makeView()
        let storage = try XCTUnwrap(view.textStorage)
        let narrow = NoteTextEditor.textHeight(storage, width: 80)
        let wide = NoteTextEditor.textHeight(storage, width: 600)
        XCTAssertGreaterThan(narrow, wide * 3)
    }

    func testContainerTracksFrameAfterMeasuring() throws {
        let view = makeView()
        let storage = try XCTUnwrap(view.textStorage)
        _ = NoteTextEditor.textHeight(storage, width: 80)
        view.setFrameSize(NSSize(width: 600, height: 300))
        XCTAssertEqual(try XCTUnwrap(view.textContainer).containerSize.width, 600)
    }

    func testMeasuringAtAnotherWidthLeavesTheContainerAlone() throws {
        let view = makeView()
        view.setFrameSize(NSSize(width: 600, height: 300))
        let cache = NoteTextEditor.MeasureCache()
        _ = NoteTextEditor.fittingHeight(of: view, width: 80, cache: cache)
        XCTAssertEqual(try XCTUnwrap(view.textContainer).containerSize.width, 600)
    }

    func testShortcutAndThrowawayPathsAgree() throws {
        let view = makeView()
        view.setFrameSize(NSSize(width: 600, height: 300))
        let shortcut = try XCTUnwrap(NoteTextEditor.fittingHeight(of: view, width: 600))
        view.setFrameSize(NSSize(width: 300, height: 300))
        let cache = NoteTextEditor.MeasureCache()
        let throwaway = try XCTUnwrap(NoteTextEditor.fittingHeight(of: view, width: 600, cache: cache))
        let cached = try XCTUnwrap(NoteTextEditor.fittingHeight(of: view, width: 600, cache: cache))
        XCTAssertEqual(shortcut, throwaway)
        XCTAssertEqual(throwaway, cached)
    }
}
