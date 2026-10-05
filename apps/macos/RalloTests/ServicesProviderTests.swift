import AppKit
import XCTest

/// 0017: Services → New Rallo Note saves the selected text as-is.
@MainActor
final class ServicesProviderTests: XCTestCase {
    func testSelectedTextBecomesANote() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-services-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        let capture = CaptureService(waitLimit: .milliseconds(300))
        capture.attach(core: core)
        capture.showErrors { message in XCTFail("unexpected error: \(message)") }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rallo-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Deploy freeze starts Friday 5pm\nfrom #eng", forType: .string)

        var error: NSString?
        ServicesProvider(capture: capture).newRalloNote(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)

        var texts: [String] = []
        for _ in 0..<40 {
            texts = try RalloStore.open(dataDir: dataDir.path).listOpenItems(limit: 10).map(\.text)
            if !texts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(texts, ["Deploy freeze starts Friday 5pm\nfrom #eng"], "multi-line selections stay multi-line")
    }

    func testNoTextReportsAnError() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rallo-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        var error: NSString?
        ServicesProvider(capture: CaptureService(waitLimit: .milliseconds(100))).newRalloNote(pasteboard, userData: nil, error: &error)
        XCTAssertEqual(error, "No text was selected.")
    }
}
