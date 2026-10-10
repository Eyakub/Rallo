import XCTest

/// 0021 §9: the call rule and idle time.
final class QuietSignalsTests: XCTestCase {
    func testRallosOwnDictationIsNotACallButTheCameraStillIs() {
        XCTAssertFalse(QuietSignals.inUse(camera: false, microphone: false, voiceTyping: false))
        XCTAssertTrue(QuietSignals.inUse(camera: false, microphone: true, voiceTyping: false))
        XCTAssertFalse(QuietSignals.inUse(camera: false, microphone: true, voiceTyping: true))
        XCTAssertTrue(QuietSignals.inUse(camera: true, microphone: false, voiceTyping: false))
        XCTAssertTrue(QuietSignals.inUse(camera: true, microphone: true, voiceTyping: true))
    }

    @MainActor
    func testIdleSecondsIsAFiniteNonNegativeNumber() {
        let idle = QuietSignals.idleSeconds()
        XCTAssertTrue(idle.isFinite && idle >= 0, "\(idle)")
    }

    /// The device queries need no permission (spike S4) and never crash on a Mac without a camera.
    func testDeviceQueriesAnswer() {
        _ = DeviceActivity.microphoneInUse()
        _ = DeviceActivity.cameraInUse()
    }
}
