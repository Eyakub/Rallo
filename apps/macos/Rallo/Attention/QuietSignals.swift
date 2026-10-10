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

    /// A camera, or an input device, running in any process, ignoring
    /// Rallo's own voice typing. False if detection is unavailable (S4).
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
    /// Any audio device with an input stream running in any process.
    static func microphoneInUse() -> Bool {
        audioDevices().contains { hasInput($0) && audioRunning($0) }
    }

    /// Any camera running in any process.
    static func cameraInUse() -> Bool {
        cameraDevices().contains(where: cameraRunning)
    }

    private static func audioDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func audioRunning(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
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
