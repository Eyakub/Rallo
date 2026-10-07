import AppKit
import XCTest

/// 0017: Shortcuts, Siri and Services save through CaptureService.
@MainActor
final class CaptureServiceTests: XCTestCase {
    private var dataDir: URL!
    private var shown: [String] = []

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("rallo-capture-\(UUID().uuidString)")
        shown = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func attached() async throws -> CaptureService {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        let service = CaptureService(waitLimit: .milliseconds(300))
        service.showErrors { [weak self] message in self?.shown.append(message) }
        service.attach(core: core)
        return service
    }

    private func savedTexts() throws -> [String] {
        try RalloStore.open(dataDir: dataDir.path).listOpenItems(limit: 50).map(\.text)
    }

    func testAddsANoteAndAReminder() async throws {
        let service = try await attached()
        let note = try await service.addNote("Call mom")
        XCTAssertNil(note.reminder)
        let reminder = try await service.addReminder("Stretch", when: "in 2 hours")
        XCTAssertNotNil(reminder.reminder)
        XCTAssertEqual(Set(try savedTexts()), ["Call mom", "Stretch"])
    }

    func testARefusedTimeThrowsTheHintAndSavesNothing() async throws {
        let service = try await attached()
        do {
            _ = try await service.addReminder("Nope", when: "later")
            XCTFail("expected a refusal")
        } catch let failure as CaptureFailure {
            XCTAssertEqual(failure.message, "couldn't read \"later\" as a time; try \"in 2h\", \"5pm\" or \"fri 9am\"")
        }
        XCTAssertEqual(try savedTexts(), [])
    }

    func testAnEmptySelectionGoesToThePanel() async throws {
        let service = try await attached()
        await service.saveSelection("  \n ")
        XCTAssertEqual(shown.count, 1, "a failed Services save is never silent")
        XCTAssertEqual(try savedTexts(), [])
    }

    func testATooLongSelectionGoesToThePanel() async throws {
        let service = try await attached()
        await service.saveSelection(String(repeating: "a", count: 64 * 1024 + 1))
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(try savedTexts(), [])
    }

    func testGivesUpWhenTheStoreNeverOpens() async throws {
        let service = CaptureService(waitLimit: .milliseconds(200))
        do {
            _ = try await service.addNote("x")
            XCTFail("expected a timeout")
        } catch let failure as CaptureFailure {
            XCTAssertEqual(failure.message, "Rallo is still starting. Try again in a moment.")
        }
    }

    func testAFailedSaveIsReportedEvenIfTheStoreNeverOpens() async throws {
        let service = CaptureService(waitLimit: .milliseconds(200))
        service.showErrors { [weak self] message in self?.shown.append(message) }
        await service.saveSelection("x")
        XCTAssertEqual(shown, ["Rallo is still starting. Try again in a moment."])
    }

    func testWaitsForAStoreThatOpensLate() async throws {
        let core = CoreClient(dataDir: dataDir.path)
        try await core.open()
        let service = CaptureService(waitLimit: .seconds(3))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            service.attach(core: core)
        }
        let note = try await service.addNote("late")
        XCTAssertEqual(note.text, "late")
    }

    func testAnUnavailableStoreFailsAtOnceWithItsMessage() async throws {
        let service = CaptureService(waitLimit: .seconds(5))
        service.unavailable("storage broken")
        let start = ContinuousClock.now
        do {
            _ = try await service.addNote("x")
            XCTFail("expected a failure")
        } catch let failure as CaptureFailure {
            XCTAssertEqual(failure.message, "storage broken")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testAWaitingRequestFailsWhenTheStoreBecomesUnavailable() async throws {
        let service = CaptureService(waitLimit: .seconds(5))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            service.unavailable("storage broken")
        }
        let start = ContinuousClock.now
        do {
            _ = try await service.addNote("x")
            XCTFail("expected a failure")
        } catch let failure as CaptureFailure {
            XCTAssertEqual(failure.message, "storage broken")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testReminderReplyIsHonestWhenAlertsAreBlocked() {
        let reply = { CaptureService.reminderReply(label: "Fri 5:00 PM", authorization: $0) }
        XCTAssertEqual(
            reply(.denied),
            "Reminder set for Fri 5:00 PM, but it won't alert you: notifications for Rallo are off in System Settings.")
        XCTAssertEqual(
            reply(.notDetermined),
            "Reminder set for Fri 5:00 PM, but it won't alert you until you allow Rallo's notifications.")
        XCTAssertEqual(reply(.authorized), "Reminder set for Fri 5:00 PM.")
        XCTAssertEqual(reply(nil), "Reminder set for Fri 5:00 PM.")
    }

    private static var png: Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    func testAddsANoteAndAReminderWithImages() async throws {
        let service = try await attached()
        let note = try await service.addNote("", images: [Self.png])
        XCTAssertEqual(note.images.count, 1)
        let reminder = try await service.addReminder("Look at this", when: "in 2 hours", images: [Self.png])
        XCTAssertEqual(reminder.images.count, 1)
        XCTAssertNotNil(reminder.reminder)
    }

    func testANoteWithNeitherTextNorImagesIsRefused() async throws {
        let service = try await attached()
        do {
            _ = try await service.addNote("  ", images: [])
            XCTFail("expected a refusal")
        } catch let failure as CaptureFailure {
            XCTAssertEqual(failure.message, "a note needs text or an image")
        }
        XCTAssertEqual(try savedTexts(), [])
    }
}
