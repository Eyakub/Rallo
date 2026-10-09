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
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: text), palette: palette))
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
        NoteTextStyler.restyle(view, tags: tagRanges(text: text), palette: palette)
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
        XCTAssertFalse(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), palette: palette))
        XCTAssertEqual(view.string, before)
        XCTAssertTrue(view.hasMarkedText(), "restyling must not end the composition")
        view.unmarkText()
        XCTAssertTrue(NoteTextStyler.restyle(view, tags: tagRanges(text: view.string), palette: palette))
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
