import AppKit

/// The modifier key that drives voice typing (0013): hold to talk, double-tap
/// for hands-free. Rallo watches modifier keys only (`.flagsChanged`), never
/// key presses. Settings keys are read live from UserDefaults.
enum VoiceKey: String, CaseIterable {
    case rightOption, rightCommand

    static let keyKey = "voiceKey"
    static let holdKey = "voiceHoldToTalk"
    static let doubleTapKey = "voiceDoubleTap"

    static var current: VoiceKey {
        UserDefaults.standard.string(forKey: keyKey).flatMap(VoiceKey.init(rawValue:)) ?? .rightOption
    }
    static var holdToTalk: Bool { UserDefaults.standard.object(forKey: holdKey) as? Bool ?? true }
    static var doubleTap: Bool { UserDefaults.standard.object(forKey: doubleTapKey) as? Bool ?? true }

    var keyCode: UInt16 { self == .rightOption ? 61 : 54 }
    /// Device-dependent bit in `NSEvent.ModifierFlags.rawValue`:
    /// NX_DEVICERALTKEYMASK 0x40, NX_DEVICERCMDKEYMASK 0x10.
    var deviceMask: UInt { self == .rightOption ? 0x40 : 0x10 }
    /// The left-hand twin: NX_DEVICELALTKEYMASK 0x20, NX_DEVICELCMDKEYMASK 0x08.
    private var otherSideMask: UInt { self == .rightOption ? 0x20 : 0x08 }
    private var family: NSEvent.ModifierFlags { self == .rightOption ? .option : .command }

    /// Pressed with no other modifier held: ⌃⌘ then Right ⌥ (a way to type
    /// ⌃⌥⌘V) must not start a hold.
    func isAlone(_ flags: UInt) -> Bool {
        let held = NSEvent.ModifierFlags(rawValue: flags).intersection([.shift, .control, .option, .command, .function])
        return held == family && flags & otherSideMask == 0
    }
    var symbol: String { self == .rightOption ? "Right ⌥" : "Right ⌘" }
}

/// Feeds modifier-key events to a `VoiceKeyGesture`. Global key monitors need
/// Accessibility, so until it is granted this polls and installs them then.
@MainActor
final class VoiceKeyMonitor {
    var onAction: (VoiceKeyAction) -> Void = { _ in }
    var isListening: () -> Bool = { false }

    private var gesture = VoiceKeyGesture()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holdTimer: Timer?
    private var pollTimer: Timer?
    private var enabled = false

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { install() } else { uninstall() }
    }

    private func install() {
        guard VoicePermissions.accessibilityAllowed(prompt: false) else {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, VoicePermissions.accessibilityAllowed(prompt: false) else { return }
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    if self.enabled { self.install() }
                }
            }
            return
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let (code, flags) = (event.keyCode, event.modifierFlags.rawValue)
            MainActor.assumeIsolated { self?.handle(keyCode: code, flags: flags) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: event.keyCode, flags: event.modifierFlags.rawValue)
            return event
        }
    }

    private func uninstall() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        holdTimer?.invalidate()
        holdTimer = nil
        gesture = VoiceKeyGesture()
    }

    private func handle(keyCode: UInt16, flags: UInt) {
        let key = VoiceKey.current
        let now = ProcessInfo.processInfo.systemUptime
        guard keyCode == key.keyCode else {
            gesture.otherModifierChanged()
            return
        }
        if flags & key.deviceMask != 0 {
            guard key.isAlone(flags) else {
                holdTimer?.invalidate()
                holdTimer = nil
                gesture = VoiceKeyGesture()
                return
            }
            let action = gesture.keyDown(at: now, listening: isListening(), hold: VoiceKey.holdToTalk, doubleTap: VoiceKey.doubleTap)
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: VoiceKeyGesture.holdDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let action = self.gesture.holdDeadline(at: ProcessInfo.processInfo.systemUptime) else { return }
                    self.onAction(action)
                }
            }
            if let action { onAction(action) }
        } else {
            holdTimer?.invalidate()
            holdTimer = nil
            if let action = gesture.keyUp(at: now) { onAction(action) }
        }
    }
}
