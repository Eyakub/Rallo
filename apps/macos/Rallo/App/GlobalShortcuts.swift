import AppKit
import Carbon.HIToolbox

/// Registers Rallo's two global shortcuts (0008): ⌃⌥⌘J jumps to the
/// longest-waiting agent, ⌃⌥⌘N toggles the notes panel. Carbon's
/// `RegisterEventHotKey`/`InstallEventHandler` need no Accessibility or
/// Input Monitoring permission — Rallo only ever sees these two key
/// combinations, never other keystrokes. ⌃⌥⌘ because plain ⌃⌥ letters
/// collide with window managers (Rectangle uses ⌃⌥U/I/J/K).
@MainActor
final class GlobalShortcuts {
    private static let signature: OSType = 0x5241_4C4C // "RALL"
    private static let jumpID: UInt32 = 1
    private static let toggleNotesID: UInt32 = 2
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    var onJump: () -> Void = {}
    var onToggleNotes: () -> Void = {}

    /// Whether each hot key is actually registered; `false` means another
    /// app owns the combination, and the corresponding menu item says so.
    private(set) var jumpRegistered = false
    private(set) var toggleNotesRegistered = false

    private var jumpRef: EventHotKeyRef?
    private var toggleNotesRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        installHandler()
        jumpRegistered = registerHotKey(id: Self.jumpID, keyCode: UInt32(kVK_ANSI_J), ref: &jumpRef)
        toggleNotesRegistered = registerHotKey(id: Self.toggleNotesID, keyCode: UInt32(kVK_ANSI_N), ref: &toggleNotesRef)
    }

    /// Called once, at quit: an unregistered hot key would otherwise outlive
    /// the app until the next login.
    func unregister() {
        if let jumpRef { UnregisterEventHotKey(jumpRef) }
        if let toggleNotesRef { UnregisterEventHotKey(toggleNotesRef) }
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
