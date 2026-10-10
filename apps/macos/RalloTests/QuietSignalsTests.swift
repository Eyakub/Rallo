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

    // MARK: Mic in use: another process recording from a device (S4 addendum)

    private let rallo: pid_t = 500

    /// Measured: corespeechd (the voice trigger) runs input with no input device, all the time.
    func testTheVoiceTriggerIsNotACall() {
        let processes = [DeviceActivity.AudioProcess(pid: 1014, runningInput: true, inputDevices: 0)]
        XCTAssertFalse(DeviceActivity.microphoneInUse(processes, excluding: rallo))
    }

    /// Measured: `say` into BlackHole 64ch lists the device (it has an input) but runs no input.
    func testPlaybackOnADeviceWithAnInputIsNotACall() {
        let processes = [DeviceActivity.AudioProcess(pid: 61570, runningInput: false, inputDevices: 1)]
        XCTAssertFalse(DeviceActivity.microphoneInUse(processes, excluding: rallo))
    }

    func testAnotherProcessRecordingFromADeviceIsACall() {
        let processes = [DeviceActivity.AudioProcess(pid: 1014, runningInput: true, inputDevices: 0),
                         DeviceActivity.AudioProcess(pid: 700, runningInput: true, inputDevices: 1)]
        XCTAssertTrue(DeviceActivity.microphoneInUse(processes, excluding: rallo))
    }

    /// Measured 2026-10-10: corespeechd also runs input with two input devices for a few seconds at a time.
    func testTheVoiceTriggerWithInputDevicesIsNotACall() {
        let processes = [DeviceActivity.AudioProcess(pid: 1014, runningInput: true, inputDevices: 2,
                                                     bundleID: "com.apple.CoreSpeech")]
        XCTAssertFalse(DeviceActivity.microphoneInUse(processes, excluding: rallo))
    }

    func testAnUnknownBundleWithTheSameInputIsACall() {
        let processes = [DeviceActivity.AudioProcess(pid: 1014, runningInput: true, inputDevices: 2,
                                                     bundleID: "us.zoom.xos")]
        XCTAssertTrue(DeviceActivity.microphoneInUse(processes, excluding: rallo))
    }

    func testRallosOwnRecordingIsNotACall() {
        let processes = [DeviceActivity.AudioProcess(pid: rallo, runningInput: true, inputDevices: 1)]
        XCTAssertFalse(DeviceActivity.microphoneInUse(processes, excluding: rallo))
    }

    /// The device queries need no permission (spike S4) and never crash on a Mac without a camera.
    func testDeviceQueriesAnswer() {
        _ = DeviceActivity.microphoneInUse()
        _ = DeviceActivity.cameraInUse()
    }
}
