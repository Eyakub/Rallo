import XCTest

/// "Remind Me → Custom…" (0016). Time-zone independent: relative phrases only,
/// plus refusals; the zone-dependent rules are pinned in Rust.
final class CustomRemindPreviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    func testAPhraseResolvesThroughTheCore() {
        let preview = CustomRemindPreview(text: "in 2 hours", now: now)
        XCTAssertEqual(preview.date, now.addingTimeInterval(7_200))
        XCTAssertEqual(preview.message, "→ " + ReminderLabel.text(for: now.addingTimeInterval(7_200)))
    }

    func testARefusalShowsTheCoresHint() {
        let preview = CustomRemindPreview(text: "later", now: now)
        XCTAssertNil(preview.date)
        XCTAssertEqual(preview.message, "couldn't read \"later\" as a time; try \"in 2h\", \"5pm\" or \"fri 9am\"")
    }

    func testEmptyTextShowsExamples() {
        let preview = CustomRemindPreview(text: "   ", now: now)
        XCTAssertNil(preview.date)
        XCTAssertEqual(preview.message, CustomRemindPreview.examples)
    }
}
