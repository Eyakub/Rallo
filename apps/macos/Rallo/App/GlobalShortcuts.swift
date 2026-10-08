import AppKit
import Carbon.HIToolbox

/// Registers Rallo's global shortcuts (0008): ⌃⌥⌘J jumps to the
/// longest-waiting agent, ⌃⌥⌘N toggles the notes panel; ⌃⌥⌘V (hands-free
/// voice typing; the voice key, 0013, also starts it) and ⌃⌥⌘S (screenshot to
/// a note) are opt-in. Carbon's
/// `RegisterEventHotKey`/`InstallEventHandler` need no Accessibility or
/// Input Monitoring permission — Rallo only ever sees these two key
/// combinations, never other keystrokes. ⌃⌥⌘ because plain ⌃⌥ letters
/// collide with window managers (Rectangle uses ⌃⌥U/I/J/K).
@MainActor
final class GlobalShortcuts {
    private static let signature: OSType = 0x5241_4C4C // "RALL"
    private static let jumpID: UInt32 = 1
    private static let toggleNotesID: UInt32 = 2
    private static let voiceID: UInt32 = 3
    private static let screenshotID: UInt32 = 4
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    var onJump: () -> Void = {}
    var onToggleNotes: () -> Void = {}
    var onVoice: () -> Void = {}
    var onScreenshot: () -> Void = {}

    /// Whether each hot key is actually registered; `false` means another
    /// app owns the combination, and the corresponding menu item says so.
    private(set) var jumpRegistered = false
    private(set) var toggleNotesRegistered = false
    /// ⌃⌥⌘V (voice typing, 0013) is registered only while the feature is on,
    /// so it isn't taken from other apps otherwise.
    private(set) var voiceRegistered = false
    private(set) var screenshotRegistered = false

    private var jumpRef: EventHotKeyRef?
    private var toggleNotesRef: EventHotKeyRef?
    private var voiceRef: EventHotKeyRef?
    private var screenshotRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        installHandler()
        jumpRegistered = registerHotKey(id: Self.jumpID, keyCode: UInt32(kVK_ANSI_J), ref: &jumpRef)
        toggleNotesRegistered = registerHotKey(id: Self.toggleNotesID, keyCode: UInt32(kVK_ANSI_N), ref: &toggleNotesRef)
    }

    func setVoice(enabled: Bool) {
        if enabled, voiceRef == nil {
            voiceRegistered = registerHotKey(id: Self.voiceID, keyCode: UInt32(kVK_ANSI_V), ref: &voiceRef)
        } else if !enabled {
            if let voiceRef { UnregisterEventHotKey(voiceRef) }
            voiceRef = nil
            voiceRegistered = false
        }
    }

    /// ⌃⌥⌘S (screenshot to a note, 0018): registered only while the setting
    /// is on, so it isn't taken from other apps otherwise.
    func setScreenshot(enabled: Bool) {
        if enabled, screenshotRef == nil {
            screenshotRegistered = registerHotKey(id: Self.screenshotID, keyCode: UInt32(kVK_ANSI_S), ref: &screenshotRef)
        } else if !enabled {
            if let screenshotRef { UnregisterEventHotKey(screenshotRef) }
            screenshotRef = nil
            screenshotRegistered = false
        }
    }

    /// Called once, at quit: an unregistered hot key would otherwise outlive
    /// the app until the next login.
    func unregister() {
        if let jumpRef { UnregisterEventHotKey(jumpRef) }
        if let toggleNotesRef { UnregisterEventHotKey(toggleNotesRef) }
        setVoice(enabled: false)
        setScreenshot(enabled: false)
        jumpRef = nil
        toggleNotesRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch id {
                    case GlobalShortcuts.jumpID: shortcuts.onJump()
                    case GlobalShortcuts.toggleNotesID: shortcuts.onToggleNotes()
                    case GlobalShortcuts.voiceID: shortcuts.onVoice()
                    case GlobalShortcuts.screenshotID: shortcuts.onScreenshot()
                    default: break
                    }
                }
            }
            return noErr
        }, 1, &eventType, selfPointer, &handlerRef)
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, ref: inout EventHotKeyRef?) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, Self.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }
}
