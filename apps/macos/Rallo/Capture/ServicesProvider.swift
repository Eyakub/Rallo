import AppKit

/// Services → "New Rallo Note" (0017, Info.plist `NSServices`): the selected
/// text, or an image, becomes a note. macOS calls this on the main thread, only when the
/// user picks the item.
@MainActor
final class ServicesProvider: NSObject {
    private let capture: CaptureService

    init(capture: CaptureService? = nil) {
        self.capture = capture ?? .shared
    }

    @objc func newRalloNote(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pasteboard.string(forType: .string) ?? ""
        // 0018: selected text is saved as today; an image alone becomes a
        // note without text. Read now: the pasteboard is only valid during this call.
        let images = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (try? ImageClipboard.images(from: pasteboard)) ?? []
            : []
        // The core rejects empty notes and saveSelection reports why to the panel.
        Task { await capture.saveSelection(text, images: images) }
    }
}
