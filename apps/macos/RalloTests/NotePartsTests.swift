import XCTest

/// 0018: a title only when the user wrote one — a line break or ": " after
/// a short first part.
final class NotePartsTests: XCTestCase {
    func testALineBreakAfterAShortFirstLineMakesATitle() {
        let parts = NoteParts("Ledger audit logs\nStore who changed what")
        XCTAssertEqual(parts.title, "Ledger audit logs")
        XCTAssertEqual(parts.body, "Store who changed what")
    }

    func testAColonAndSpaceMakesATitle() {
        let parts = NoteParts("Investigate member approval on Launcher modules: check whether the member has access")
        XCTAssertEqual(parts.title, "Investigate member approval on Launcher modules")
        XCTAssertEqual(parts.body, "check whether the member has access")
    }

    func testOneParagraphHasNoTitle() {
        let text = "Launcher (Hub One /launch, 'Your modules' page) shows modules the member can't open"
        let parts = NoteParts(text)
        XCTAssertNil(parts.title)
        XCTAssertEqual(parts.body, text)
    }

    func testALongFirstPartIsNotATitle() {
        let long = String(repeating: "a", count: 61)
        XCTAssertNil(NoteParts("\(long)\nmore").title)
        XCTAssertNil(NoteParts("\(long): more").title)
        XCTAssertEqual(NoteParts(String(repeating: "b", count: 60) + "\nmore").title, String(repeating: "b", count: 60))
    }

    func testColonsWithoutASpaceNeverSplit() {
        XCTAssertNil(NoteParts("Standup at 5:30pm tomorrow").title)
        XCTAssertNil(NoteParts("See https://example.com/page for details").title)
        XCTAssertNil(NoteParts("ratio a:b changed").title)
    }

    func testNothingAfterTheBreakIsNotATitle() {
        XCTAssertNil(NoteParts("Call the dentist").title)
        XCTAssertNil(NoteParts("Heads up: ").title)
        XCTAssertNil(NoteParts("Call the dentist\n\n").title)
    }

    func testTheLineBreakWinsOverAColonLaterInTheNote() {
        let parts = NoteParts("Deploy\nnote: freeze starts fri")
        XCTAssertEqual(parts.title, "Deploy")
        XCTAssertEqual(parts.body, "note: freeze starts fri")
    }

    func testPreviewFlattensTheBody() {
        XCTAssertEqual(NoteParts("Title\nline one\n  line two").preview, "line one line two")
    }

    func testEmptyText() {
        let parts = NoteParts("")
        XCTAssertNil(parts.title)
        XCTAssertEqual(parts.body, "")
    }

    func testNameIsTheTitleOrTheFirstLine() {
        XCTAssertEqual(NoteParts("Deploy\nfreeze starts fri").name, "Deploy")
        XCTAssertEqual(NoteParts("Call the dentist").name, "Call the dentist")
        XCTAssertEqual(NoteParts(String(repeating: "a", count: 70) + "\nmore").name, String(repeating: "a", count: 70))
    }
}
