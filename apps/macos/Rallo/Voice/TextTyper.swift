import CoreGraphics

/// Types text into the focused app as synthetic keystrokes (0013).
enum TextTyper {
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for chunk in VoiceText.chunks(text) {
            let units = Array(chunk.utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                // The user is still holding ⌃⌥⌘ from the shortcut; without
                // this the text would arrive as shortcuts.
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
