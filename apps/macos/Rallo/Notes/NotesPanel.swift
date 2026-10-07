import AppKit
import Quartz
import SwiftUI

/// The compact notes panel. Unlike the pet, opening it is an explicit request
/// to type, so it activates Rallo and takes keyboard focus.
@MainActor
final class NotesPanelController: NSObject, NSWindowDelegate {
    let model: NotesViewModel
    private var panel: NSPanel?

    init(model: NotesViewModel) {
        self.model = model
    }

    var window: NSWindow? { panel }
    var isOpen: Bool { panel?.isVisible ?? false }

    func open(near anchor: NSRect?) {
        model.captureError = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            panel.setFrameOrigin(origin(for: panel.frame.size, near: anchor))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        model.requestFocus()
        Task { await model.reload() }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NotesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Rallo Notes"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onEscape = { [weak model] in model?.handleEscape() ?? false }
        let hosting = NSHostingView(rootView: NotesView(model: model))
        panel.contentView = hosting
        // The hosting view adds the title bar's height only when it first
        // lays out; size the panel now so the first open is placed from its
        // real height instead of overlapping the pet.
        panel.setContentSize(hosting.fittingSize)
        // A compact panel only closes; minimise/zoom would be dead controls.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    /// Above-left of the pet when possible, inside the pet's display.
    private func origin(for size: NSSize, near anchor: NSRect?) -> NSPoint {
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } } ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return .zero }
        guard let anchor else {
            return NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }
        let x = min(max(anchor.maxX - size.width, area.minX + 8), area.maxX - size.width - 8)
        let above = anchor.maxY + 8
        let y = above + size.height <= area.maxY ? above : max(area.minY + 8, anchor.minY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

/// Esc steps back (stop editing, collapse a note) and finally closes the
/// panel, as the escape route from any panel should.
private final class NotesWindow: NSPanel {
    var onEscape: () -> Bool = { false }

    override func cancelOperation(_ sender: Any?) {
        if !onEscape() {
            orderOut(sender)
        }
    }

    // Quick Look asks the responder chain who supplies its items (0018).
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookPresenter.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}
