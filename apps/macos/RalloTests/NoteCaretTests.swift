import XCTest

final class NoteCaretTests: XCTestCase {
    private func r(_ l: Int, _ n: Int) -> NSRange { NSRange(location: l, length: n) }

    private func runs(_ text: String, shown: NSRange? = nil) -> [NoteCaret.Run] {
        NoteCaret.runs(text: text as NSString, marks: markdownSpans(text: text), shown: shown)
    }

    /// The caret after a move from `o` to `p`, as the delegate would snap it.
    private func move(_ text: String, _ o: Int, _ p: Int, mouse: Bool = false, shown: NSRange? = nil) -> Int {
        NoteCaret.adjust(from: r(o, 0), to: r(p, 0), runs: runs(text, shown: shown), length: (text as NSString).length, mouse: mouse).location
    }

    private func check(_ text: String, _ moves: [(Int, Int, Int)], mouse: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        for (o, p, expected) in moves {
            XCTAssertEqual(move(text, o, p, mouse: mouse), expected, "\(o)->\(p) in \(text.debugDescription)", file: file, line: line)
        }
    }

    func testRunsOfInlineMarks() {
        XCTAssertEqual(runs("x**bold**y"), [.init(range: r(1, 2), side: .start), .init(range: r(7, 2), side: .end)])
    }

    func testMouseRestsAtTheSideOfTheMark() {
        check("x**bold**y", [(5, 2, 1), (5, 3, 1), (5, 7, 9), (5, 8, 9)], mouse: true)
    }

    func testKeyboardStepsOverInlineMarks() {
        check("x**bold**y", [(0, 1, 1), (1, 2, 4), (6, 7, 9), (9, 10, 10), (10, 9, 9), (9, 8, 6), (4, 3, 1), (1, 0, 0)])
    }

    func testEmptyLooking() {
        check("**a**", [(0, 1, 5), (5, 4, 0)])
        check("**ab**", [(4, 5, 6)])
    }

    func testHeadingPrefix() {
        check("# Title\nnext", [(5, 0, 2)], mouse: true)
        check("# Title\nnext", [(2, 1, 2)])
        check("a\n# T", [(4, 3, 1), (1, 2, 4)])
    }

    func testListPrefix() {
        check("- one\n- two", [(8, 7, 5)])
        check("- one\n- two", [(0, 6, 8)], mouse: true)
        check("- [ ] task", [(9, 0, 6)], mouse: true)
    }

    func testCodeFenceLines() {
        let text = "a\n```\ncode\n```\nb"
        XCTAssertEqual(runs(text), [.init(range: r(2, 4), side: .line), .init(range: r(11, 4), side: .line)])
        check(text, [(1, 2, 6), (6, 5, 1), (10, 11, 15), (15, 14, 10), (0, 3, 6)])
    }

    func testClosingFenceAtTheTextEnd() {
        XCTAssertEqual(runs("```\nx\n```").last, .init(range: r(6, 3), side: .line))
        check("```\nx\n```", [(5, 6, 9)])
        // A trailing newline leaves its empty last line to the caret.
        XCTAssertEqual(runs("```\nx\n```\n").last, .init(range: r(6, 3), side: .line))
    }

    func testDividerLine() {
        check("a\n---\nb", [(1, 2, 6), (6, 5, 1)])
    }

    func testLinkMarksHideUnlessShown() {
        let text = "see [site](http://x.y) now"
        check(text, [(0, 4, 4), (0, 5, 4)], mouse: true)
        check(text, [(4, 5, 6)])
        let link = r(4, 18)
        XCTAssertEqual(move(text, 0, 5, mouse: true, shown: link), 5)
        XCTAssertTrue(runs(text, shown: link).isEmpty)
    }

    func testTouchingMarksAreOneSpot() {
        for p in 4...7 { XCTAssertEqual(move("x**a**_b_", 0, p, mouse: true), 6, "\(p)") }
    }

    func testHeadingWithBoldRestsAfterThePrefix() {
        XCTAssertEqual(move("# **B**", 7, 3, mouse: true), 2)
    }

    func testRangedSelections() {
        let text = "x**bold**y", runs = self.runs(text)
        XCTAssertEqual(NoteCaret.adjust(from: r(1, 0), to: r(1, 1), runs: runs, length: 10, mouse: false), r(1, 3))
        XCTAssertEqual(NoteCaret.adjust(from: r(1, 0), to: r(0, 10), runs: runs, length: 10, mouse: false), r(0, 10))
        // Extending back over the opener from after it collapses at the fixed end rather than crossing.
        XCTAssertEqual(NoteCaret.adjust(from: r(5, 2), to: r(5, 0), runs: runs, length: 10, mouse: false), r(5, 0))
    }
}
