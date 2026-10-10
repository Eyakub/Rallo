import CoreAudio
import CoreGraphics
import CoreMediaIO

/// "Should Rallo hold back right now?" (0021 §9, 0022 §6).
@MainActor final class QuietSignals {
    /// Rallo's own voice typing; its mic use doesn't count.
    var isVoiceTypingListening: () -> Bool = { false }

    /// shortcut: spike S1 failed (INFocusStatusCenter unavailable to this build); revisit with a Developer ID.
    func requestFocusAuthorization() {}

    /// Always false: see `requestFocusAuthorization()`.
    var focusOn: Bool { false }

    /// A camera running in any process, or another process recording from an
    /// audio device, ignoring Rallo's own voice typing. False if detection
    /// is unavailable (S4).
    var cameraOrMicInUse: Bool {
        Self.inUse(camera: DeviceActivity.cameraInUse(), microphone: DeviceActivity.microphoneInUse(),
                   voiceTyping: isVoiceTypingListening())
    }

    /// Seconds since the last keyboard or mouse event (kCGAnyInputEventType).
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// While Rallo itself dictates the mic is busy; only the camera counts then.
    nonisolated static func inUse(camera: Bool, microphone: Bool, voiceTyping: Bool) -> Bool {
        camera || (microphone && !voiceTyping)
    }
}

/// Camera and microphone in use by any process (0021 §9; spike S4).
enum DeviceActivity {
    /// One CoreAudio client process, as the mic check reads it.
    struct AudioProcess: Equatable {
        var pid: pid_t
        var runningInput: Bool
        /// The devices it uses for input.
        var inputDevices: Int
    }

    /// Another process recording from an audio device. Asked per process: a
    /// device's own running flag also counts output on a device that has an
    /// input too, such as a headset (0021 Verified, S4 addendum).
    static func microphoneInUse() -> Bool {
        microphoneInUse(audioProcesses(), excluding: ProcessInfo.processInfo.processIdentifier)
    }

    /// The voice trigger (corespeechd) runs input with no device; playback on
    /// a device with an input lists the device but runs no input. Neither counts.
    static func microphoneInUse(_ processes: [AudioProcess], excluding ownPID: pid_t) -> Bool {
        processes.contains { $0.pid != ownPID && $0.runningInput && $0.inputDevices > 0 }
    }

    /// Any camera running in any process.
    static func cameraInUse() -> Bool {
        cameraDevices().contains(where: cameraRunning)
    }

    private static func audioProcesses() -> [AudioProcess] {
        objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid: pid_t = scalar(id, kAudioProcessPropertyPID),
                  let running: UInt32 = scalar(id, kAudioProcessPropertyIsRunningInput) else { return nil }
            return AudioProcess(pid: pid, runningInput: running != 0,
                                inputDevices: objectIDs(id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput).count)
        }
    }

    private static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func scalar<Value: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Value = 0
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func cameraRunning(_ id: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        var running: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr
            && running != 0
    }
}
