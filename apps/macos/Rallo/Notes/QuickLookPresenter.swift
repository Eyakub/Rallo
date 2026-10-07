import Quartz

/// Quick Look on a note's images (0018). The notes window hands the shared
/// panel this data source (`NotesWindow`); arrow keys move between images.
/// Files missing from disk are skipped.
@MainActor
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var urls: [URL] = []

    func show(_ images: [ImageSnapshot], at index: Int) {
        let selected = images.indices.contains(index) ? images[index].path : nil
        urls = images.map { URL(fileURLWithPath: $0.path) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex { $0.path == selected } ?? 0
        panel.makeKeyAndOrderFront(nil)
    }

    /// Space: opens on the first image, or closes the preview.
    func toggle(_ images: [ImageSnapshot]) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            show(images, at: 0)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
