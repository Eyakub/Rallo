import XCTest

final class NoteFormattingTests: XCTestCase {
    private func r(_ l: Int, _ n: Int) -> NSRange { NSRange(location: l, length: n) }

    private func apply(_ edit: FormatEdit?, to text: String, file: StaticString = #filePath, line: UInt = #line) -> (text: String, sel: NSRange) {
        guard let edit else {
            XCTFail("expected an edit", file: file, line: line)
            return (text, r(0, 0))
        }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    private func check(_ edit: FormatEdit?, on text: String, gives expected: String, _ sel: NSRange? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let out = apply(edit, to: text, file: file, line: line)
        XCTAssertEqual(out.text, expected, file: file, line: line)
        if let sel { XCTAssertEqual(out.sel, sel, file: file, line: line) }
    }

    private func toggle(_ mark: InlineMark, _ text: String, _ sel: NSRange) -> FormatEdit {
        NoteFormatting.toggle(mark, text: text, selection: sel, marks: markdownSpans(text: text))
    }

    private func block(_ style: BlockStyle, _ text: String, _ sel: NSRange) -> FormatEdit {
        NoteFormatting.setBlock(style, text: text, selection: sel)
    }

    private func newline(_ text: String, _ sel: NSRange) -> FormatEdit? {
        NoteFormatting.newline(text: text, selection: sel, marks: markdownSpans(text: text))
    }

    // MARK: Inline marks

    func testBoldWrapsTheSelectionAndKeepsItSelected() {
        check(toggle(.bold, "Ship rich text", r(5, 4)), on: "Ship rich text", gives: "Ship **rich** text", r(7, 4))
    }

    func testBoldUnwrapsASelectionInsideBold() {
        check(toggle(.bold, "Ship **rich** text", r(7, 4)), on: "Ship **rich** text", gives: "Ship rich text", r(5, 4))
    }

    func testBoldOnAnEmptyCaretInsertsRemovesAndStepsOut() {
        check(toggle(.bold, "ab", r(2, 0)), on: "ab", gives: "ab****", r(4, 0))
        check(toggle(.bold, "ab****", r(4, 0)), on: "ab****", gives: "ab", r(2, 0))
        check(toggle(.bold, "**bold** x", r(6, 0)), on: "**bold** x", gives: "**bold** x", r(8, 0))
    }

    func testAnInlineMarkIsAddedPerLineAndTrailingSpaceStaysOutside() {
        check(toggle(.bold, "one\ntwo", r(0, 7)), on: "one\ntwo", gives: "**one**\n**two**", r(0, 15))
        check(toggle(.bold, "rich ", r(0, 5)), on: "rich ", gives: "**rich** ")
    }

    func testItalicStrikeAndCodeWriteTheirOwnDelimiters() {
        check(toggle(.italic, "a b", r(2, 1)), on: "a b", gives: "a *b*", r(3, 1))
        check(toggle(.strike, "a b", r(2, 1)), on: "a b", gives: "a ~~b~~", r(4, 1))
        check(toggle(.code, "a b", r(2, 1)), on: "a b", gives: "a `b`", r(3, 1))
    }

    func testMarksCountUTF16ForBanglaAndEmoji() {
        let text = "কাজ 🦊 করো"
        let sel = r(4, 2) // the fox
        check(toggle(.bold, text, sel), on: text, gives: "কাজ **🦊** করো", r(6, 2))
        let bold = "কাজ **🦊** করো"
        check(toggle(.bold, bold, r(6, 2)), on: bold, gives: text, sel)
    }

    // MARK: Blocks

    func testBulletedTogglesOnAndOffOverSeveralLines() {
        check(block(.bulleted, "a\nb", r(0, 3)), on: "a\nb", gives: "- a\n- b")
        check(block(.bulleted, "- a\n- b", r(0, 7)), on: "- a\n- b", gives: "a\nb")
    }

    func testNumberedChecklistHeadingAndBodyReplaceTheOldPrefix() {
        check(block(.numbered, "a\nb", r(0, 3)), on: "a\nb", gives: "1. a\n2. b")
        check(block(.checklist, "- a", r(0, 3)), on: "- a", gives: "- [ ] a")
        check(block(.heading, "## x", r(0, 4)), on: "## x", gives: "# x")
        check(block(.heading, "# x", r(0, 3)), on: "# x", gives: "x")
        check(block(.body, "> q", r(0, 3)), on: "> q", gives: "q")
    }

    func testABlockOnACaretKeepsTheCaretOnTheSameText() {
        check(block(.bulleted, "abc", r(1, 0)), on: "abc", gives: "- abc", r(3, 0))
    }

    func testListStylesKeepIndentation() {
        check(block(.checklist, "  - a", r(0, 5)), on: "  - a", gives: "  - [ ] a")
    }

    // MARK: Return, Tab

    func testReturnContinuesLists() {
        check(newline("- milk", r(6, 0)), on: "- milk", gives: "- milk\n- ", r(9, 0))
        check(newline("1. a", r(4, 0)), on: "1. a", gives: "1. a\n2. ")
        check(newline("- [x] a", r(7, 0)), on: "- [x] a", gives: "- [x] a\n- [ ] ")
        check(newline("  - a", r(5, 0)), on: "  - a", gives: "  - a\n  - ")
        check(newline("- milk", r(4, 0)), on: "- milk", gives: "- mi\n- lk", r(7, 0))
        check(newline("> q", r(3, 0)), on: "> q", gives: "> q\n> ")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        check(newline("- ", r(2, 0)), on: "- ", gives: "", r(0, 0))
    }

    func testReturnIsPlainOutsideListsInCodeBlocksAndOverASelection() {
        XCTAssertNil(newline("abc", r(3, 0)))
        XCTAssertNil(newline("```\n- a\n```", r(7, 0)))
        XCTAssertNil(newline("- a", r(0, 3)))
    }

    func testIndentAndOutdentMoveListLines() {
        check(NoteFormatting.indent(text: "- a", selection: r(3, 0), outdent: false), on: "- a", gives: "  - a", r(5, 0))
        check(NoteFormatting.indent(text: "  - a", selection: r(5, 0), outdent: true), on: "  - a", gives: "- a", r(3, 0))
        XCTAssertNil(NoteFormatting.indent(text: "plain", selection: r(0, 0), outdent: false))
    }

    // MARK: Checked, link, divider, code block

    func testMarkAsCheckedFlipsTheBoxes() {
        check(NoteFormatting.toggleChecked(text: "- [ ] a", selection: r(0, 0)), on: "- [ ] a", gives: "- [x] a")
        check(NoteFormatting.toggleChecked(text: "- [x] a", selection: r(0, 0)), on: "- [x] a", gives: "- [ ] a")
        check(NoteFormatting.toggleChecked(text: "- [x] a\n- [ ] b", selection: r(0, 15)), on: "- [x] a\n- [ ] b", gives: "- [x] a\n- [x] b")
        XCTAssertNil(NoteFormatting.toggleChecked(text: "a", selection: r(0, 0)))
    }

    func testAddLinkWrapsTheSelectionAndPlacesTheCaretInTheURL() {
        check(NoteFormatting.addLink(text: "see docs", selection: r(4, 4)), on: "see docs", gives: "see [docs]()", r(11, 0))
        check(NoteFormatting.addLink(text: "x", selection: r(1, 0)), on: "x", gives: "x[]()", r(2, 0))
    }

    func testInsertDividerGoesAfterTheLine() {
        check(NoteFormatting.insertDivider(text: "abc", selection: r(3, 0)), on: "abc", gives: "abc\n\n---\n", r(9, 0))
    }

    func testCodeBlockWrapsAndUnwraps() {
        let wrapped = "```\na\nb\n```"
        check(NoteFormatting.toggleCodeBlock(text: "a\nb", selection: r(0, 3), marks: markdownSpans(text: "a\nb")), on: "a\nb", gives: wrapped)
        check(NoteFormatting.toggleCodeBlock(text: wrapped, selection: r(5, 0), marks: markdownSpans(text: wrapped)), on: wrapped, gives: "a\nb")
    }

    // MARK: Fix round 1

    func testBoldMergesWithSpansItOverlaps() {
        check(toggle(.bold, "**ab** cd", r(2, 6)), on: "**ab** cd", gives: "**ab c**d", r(2, 4))
        check(toggle(.bold, "**a** b **c**", r(0, 13)), on: "**a** b **c**", gives: "**a b c**", r(2, 5))
    }

    func testUnwrapAcrossLinesSelectsTheFormerContent() {
        check(toggle(.bold, "**a**\n**b**", r(0, 11)), on: "**a**\n**b**", gives: "a\nb", r(0, 3))
    }

    func testCaretInsideASpanButNotAtItsCloserInsertsANewPair() {
        check(toggle(.bold, "**bold** x", r(4, 0)), on: "**bold** x", gives: "**bo****ld** x", r(6, 0))
    }

    func testItalicOnTheMiddleOfFourStarsInsertsInsteadOfRemoving() {
        check(toggle(.italic, "****", r(2, 0)), on: "****", gives: "******", r(3, 0))
    }

    func testWhitespaceOnlySelectionActsAsACaretAtItsStart() {
        check(toggle(.bold, "a  b", r(1, 2)), on: "a  b", gives: "a****  b", r(3, 0))
    }

    func testMoreReturnCases() {
        check(newline("1) a", r(4, 0)), on: "1) a", gives: "1) a\n2) ")
        check(newline("* [x] a", r(7, 0)), on: "* [x] a", gives: "* [x] a\n* [ ] ")
        check(newline("9. x", r(4, 0)), on: "9. x", gives: "9. x\n10. ")
        check(newline("  * [x] a", r(9, 0)), on: "  * [x] a", gives: "  * [x] a\n  * [ ] ")
        XCTAssertNil(newline("- a", r(0, 0)))
    }

    func testMoreBlockCases() {
        check(block(.bulleted, "  a\n  b", r(0, 7)), on: "  a\n  b", gives: "  - a\n  - b")
        check(block(.heading, "- a", r(0, 3)), on: "- a", gives: "# a")
        check(block(.quote, "- a", r(0, 3)), on: "- a", gives: "> a")
        check(block(.heading, "  - a", r(0, 5)), on: "  - a", gives: "# a")
        check(block(.bulleted, "", r(0, 0)), on: "", gives: "- ", r(2, 0))
        check(block(.bulleted, "a\nb", r(3, 0)), on: "a\nb", gives: "a\n- b", r(5, 0))
        check(block(.bulleted, "- a\r\n- b", r(0, 8)), on: "- a\r\n- b", gives: "a\r\nb")
        check(block(.bulleted, "a\nb", r(0, 2)), on: "a\nb", gives: "- a\nb")
    }

    func testMoreCheckedCodeBlockAndOutdentCases() {
        check(NoteFormatting.toggleChecked(text: "* [ ] a", selection: r(0, 0)), on: "* [ ] a", gives: "* [x] a")
        check(NoteFormatting.toggleChecked(text: "+ [X] a", selection: r(0, 0)), on: "+ [X] a", gives: "+ [ ] a")
        let open = "```\na"
        check(NoteFormatting.toggleCodeBlock(text: open, selection: r(5, 0), marks: markdownSpans(text: open)), on: open, gives: "a")
        XCTAssertEqual(NoteFormatting.indent(text: "- a", selection: r(3, 0), outdent: true),
                       FormatEdit(range: r(3, 0), replacement: "", selection: r(3, 0)))
    }

    // MARK: Final review

    private func kinds(_ text: String) -> (bold: Bool, italic: Bool) {
        let spans = markdownSpans(text: text)
        return (spans.contains { $0.kind == .bold }, spans.contains { $0.kind == .italic })
    }

    private func applied(_ edit: FormatEdit, to text: String) -> (text: String, sel: NSRange) {
        (((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)), edit.selection)
    }

    func testBoldThenItalicOnTheSameWordKeepsBothStyles() {
        let bold = applied(toggle(.bold, "word", r(0, 4)), to: "word")
        XCTAssertEqual(bold.text, "**word**")
        let both = applied(toggle(.italic, bold.text, bold.sel), to: bold.text)
        XCTAssertEqual(both.text, "**_word_**")
        XCTAssertTrue(kinds(both.text).bold && kinds(both.text).italic)
    }

    func testItalicThenBoldAndItalicOverBoldKeepBothStyles() {
        let italic = applied(toggle(.italic, "word", r(0, 4)), to: "word")
        let both = applied(toggle(.bold, italic.text, italic.sel), to: italic.text)
        XCTAssertTrue(kinds(both.text).bold && kinds(both.text).italic, both.text)
        let over = applied(toggle(.italic, "**word**", r(0, 8)), to: "**word**")
        XCTAssertTrue(kinds(over.text).bold && kinds(over.text).italic, over.text)
    }

    func testBoldOverItalicAndBoldNeverMakesAStarRun() {
        let out = applied(toggle(.bold, "*i* **b**", r(0, 9)), to: "*i* **b**")
        XCTAssertFalse(out.text.contains("***"), out.text)
        XCTAssertTrue(kinds(out.text).bold && kinds(out.text).italic, out.text)
    }

    func testBoldAtTheCaretRightAfterTheOpenerStepsOutBeforeIt() {
        XCTAssertEqual(toggle(.bold, "**bold**", r(2, 0)), FormatEdit(range: r(0, 0), replacement: "", selection: r(0, 0)))
    }

    func testPrefixesFollowTheCoreGrammar() {
        XCTAssertNil(newline("\t- item", r(7, 0)))
        check(block(.quote, ">q", r(2, 0)), on: ">q", gives: "q")
        XCTAssertEqual(NoteFormatting.blockStyle(text: "####### x", at: 0), .body)
        XCTAssertEqual(NoteFormatting.blockStyle(text: "###### x", at: 0), .subheading)
        check(NoteFormatting.toggleChecked(text: "-  [ ] a", selection: r(0, 0)), on: "-  [ ] a", gives: "-  [x] a")
    }

    // MARK: Queries

    func testBlockStyleAndIsInside() {
        XCTAssertEqual(NoteFormatting.blockStyle(text: "- [ ] a", at: 3), .checklist)
        XCTAssertEqual(NoteFormatting.blockStyle(text: "## a", at: 0), .subheading)
        XCTAssertEqual(NoteFormatting.blockStyle(text: "a", at: 0), .body)
        XCTAssertTrue(NoteFormatting.isInside(.bold, location: 7, marks: markdownSpans(text: "Ship **rich**")))
        XCTAssertFalse(NoteFormatting.isInside(.italic, location: 7, marks: markdownSpans(text: "Ship **rich**")))
    }
}
