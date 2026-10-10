import AVFoundation
import UserNotifications
import XCTest

/// 0021 §6: the chime choices, their files, and the banner's sound.
final class AlertSoundTests: XCTestCase {
    private let sounds = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Rallo/Resources/Sounds")

    func testTheMenuOffersTheSpecsChoicesInOrder() {
        XCTAssertEqual(AlertSound.menuOrder.map(\.title), ["Rallo Chime", "Bamboo Knock", "Gentle Bell", "System default", "None"])
    }

    func testEveryRalloChimeIsAShortBundledCAF() throws {
        for sound in [AlertSound.ralloChime, .bambooKnock, .gentleBell] {
            let name = try XCTUnwrap(sound.fileName)
            XCTAssertTrue(name.hasSuffix(".caf"))
            let file = try AVAudioFile(forReading: sounds.appendingPathComponent(name))
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            XCTAssertTrue((1.4...3.1).contains(seconds), "\(name) lasts \(seconds) s")
        }
    }

    func testSystemAndNoneHaveNoFile() {
        XCTAssertNil(AlertSound.system.fileName)
        XCTAssertNil(AlertSound.none.fileName)
    }

    func testTheBannerSound() {
        XCTAssertNil(AlertSound.none.notificationSound, "None: a silent banner")
        XCTAssertNotNil(AlertSound.system.notificationSound)
        XCTAssertNotNil(AlertSound.ralloChime.notificationSound)
    }
}
