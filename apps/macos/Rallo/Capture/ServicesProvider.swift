import AppKit

/// Services → "New Rallo Note" (0017, Info.plist `NSServices`): the selected
/// text becomes a note. macOS calls this on the main thread, only when the
/// user picks the item.
@MainActor
final class ServicesProvider: NSObject {
    private let capture: CaptureService

    init(capture: CaptureService? = nil) {
        self.capture = capture ?? .shared
    }

    @objc func newRalloNote(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // The core rejects empty text and saveSelection reports why to the panel.
        Task { await capture.saveSelection(pasteboard.string(forType: .string) ?? "") }
    }
}
