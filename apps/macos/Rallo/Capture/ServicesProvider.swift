import AppKit

/// Services → "New Rallo Note" (0017, Info.plist `NSServices`): the selected
/// text becomes a note. macOS calls this on the main thread, only when the
/// user picks the item.
@MainActor
final class ServicesProvider: NSObject {
    private let capture: CaptureService

    init(capture: CaptureService = .shared) {
        self.capture = capture
    }

    @objc func newRalloNote(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else {
            error.pointee = "No text was selected."
            return
        }
        Task { await capture.saveSelection(text) }
    }
}
