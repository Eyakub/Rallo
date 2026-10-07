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

    func testNoTextReportsAnError() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-services-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        let capture = CaptureService(waitLimit: .milliseconds(300))
        capture.attach(core: core)
        let reported = expectation(description: "error reaches the panel")
        var message = ""
        capture.showErrors {
            message = $0
            reported.fulfill()
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rallo-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        var error: NSString?
        ServicesProvider(capture: capture).newRalloNote(pasteboard, userData: nil, error: &error)

        await fulfillment(of: [reported], timeout: 3)
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(try RalloStore.open(dataDir: dataDir.path).listOpenItems(limit: 10).map(\.text), [])
    }

    private static var png: Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    private func savedItems(_ dataDir: URL) async throws -> [ItemSnapshot] {
        for _ in 0..<40 {
            let items = try RalloStore.open(dataDir: dataDir.path).listOpenItems(limit: 10)
            if !items.isEmpty { return items }
            try await Task.sleep(for: .milliseconds(50))
        }
        return []
    }

    func testASelectedImageBecomesANoteWithoutText() async throws {
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
        pasteboard.setData(Self.png, forType: .png)
        var error: NSString?
        ServicesProvider(capture: capture).newRalloNote(pasteboard, userData: nil, error: &error)

        let items = try await savedItems(dataDir)
        XCTAssertEqual(items.map(\.text), [""])
        XCTAssertEqual(items.first?.images.map(\.mimeType), ["image/png"])
    }

    func testSelectedTextWinsOverAnImage() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-services-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        let capture = CaptureService(waitLimit: .milliseconds(300))
        capture.attach(core: core)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rallo-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("Caption", forType: .string)
        item.setData(Self.png, forType: .png)
        pasteboard.writeObjects([item])
        var error: NSString?
        ServicesProvider(capture: capture).newRalloNote(pasteboard, userData: nil, error: &error)

        let items = try await savedItems(dataDir)
        XCTAssertEqual(items.map(\.text), ["Caption"])
        XCTAssertEqual(items.first?.images, [])
    }
}
