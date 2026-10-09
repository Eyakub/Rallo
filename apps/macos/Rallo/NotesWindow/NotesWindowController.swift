import AppKit
import Quartz
import SwiftUI

/// The Notes window (0019 §11): a titled, resizable window around the
/// three-column `NotesWindowView`. One window is kept for the life of the app;
/// opening it makes Rallo a Dock app, closing it (red button, ⌘W) makes it a
/// menu-bar app again.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    let model: NotesWindowModel
    /// The coordinator's scratch-aware defaults: AppKit's frame autosave would
    /// write the real app's domain from a scratch build (same bundle id).
    private let defaults: UserDefaults
    private static let frameKey = "RalloNotesWindow"
    private var window: NSWindow?
    /// Told when the window opens (true) and closes (false), so the activation
    /// policy follows it. A closing window still reads `isVisible`, hence the argument.
    var onPresenceChange: (Bool) -> Void = { _ in }

    init(model: NotesWindowModel, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
    }

    /// Showing, or minimised to the Dock.
    var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }
    var isKey: Bool { window?.isKeyWindow ?? false }
    var nsWindow: NSWindow? { window }

    /// Opens (or brings forward) the window; `selection` and `noteID` come from
    /// the panel's expand button, nil keeps what the window last showed.
    func show(selection: NotesWindowSelection? = nil, noteID: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        onPresenceChange(true)  // `.regular` first, so the window can become key
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await model.opened(selection: selection, noteID: noteID) }
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)  // the input method commits marked text before the editor saves
        rememberFrame()
        // After AppKit's close sequence: switching the policy inside it can leave the menu bar unpainted.
        DispatchQueue.main.async { [weak self] in self?.onPresenceChange(false) }
        Task { await model.closed() }
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    /// ⌘F: the toolbar's search field (`.searchable` puts an `NSSearchToolbarItem` there).
    func focusSearch() {
        let search = window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
        search?.beginSearchInteraction()
    }

    private func rememberFrame() {
        if let window { defaults.set(window.frameDescriptor, forKey: Self.frameKey) }
    }

    private func makeWindow() -> NSWindow {
        let window = NotesAppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Not "Rallo Notes": that is the panel's title, and Mission Control and
        // the window report must tell the two apart.
        window.title = "Notes"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.delegate = self
        let hosting = NSHostingController(rootView: NotesWindowView(model: model))
        hosting.sizingOptions = []  // the window decides its size, not the SwiftUI content
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1140, height: 690))
        if let saved = defaults.string(forKey: Self.frameKey) {
            window.setFrame(from: saved)
        } else {
            window.center()
        }
        return window
    }
}

/// Quick Look asks the responder chain who supplies its items (0018), as it
/// does for the panel.
final class NotesAppWindow: NSWindow {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookPresenter.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}
