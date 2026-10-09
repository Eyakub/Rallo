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
    /// True from `show()` to `windowWillClose`: `isVisible` is false while Rallo is hidden (Dock Hide).
    private var presence = false
    /// Told when the window opens (true) and closes (false), so the activation
    /// policy follows it. A closing window still reads `isVisible`, hence the argument.
    var onPresenceChange: (Bool) -> Void = { _ in }

    init(model: NotesWindowModel, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
    }

    /// Showing, or minimised to the Dock.
    var isOpen: Bool { presence }
    var isKey: Bool { window?.isKeyWindow ?? false }
    var nsWindow: NSWindow? { window }

    /// Opens (or brings forward) the window; `selection` and `noteID` come from
    /// the panel's expand button, nil keeps what the window last showed.
    func show(selection: NotesWindowSelection? = nil, noteID: String? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        presence = true
        onPresenceChange(true)  // `.regular` first, so the window can become key
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await model.opened(selection: selection, noteID: noteID) }
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)  // the input method commits marked text before the editor saves
        rememberFrame()
        presence = false
        // After AppKit's close sequence: switching the policy inside it can leave the menu bar unpainted.
        // A show() in between wins.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.presence else { return }
            self.onPresenceChange(false)
        }
        Task { await model.closed() }
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

    func windowDidResize(_ notification: Notification) { rememberFrame() }

    func windowDidMove(_ notification: Notification) { rememberFrame() }

    /// ⌘F: the toolbar's search field (`.searchable` puts an `NSSearchToolbarItem` there).
    func focusSearch() {
        let search = window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
        search?.beginSearchInteraction()
    }

    private func rememberFrame() {
        // Full screen must never become the remembered normal frame.
        if let window, !window.styleMask.contains(.fullScreen) { defaults.set(window.frameDescriptor, forKey: Self.frameKey) }
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
        // The toolbar strip over the list and editor shows the window's own background, which is
        // plain white in Light. Warm it to the columns' top surface; Dark keeps the system colour.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .windowBackgroundColor
                : NSColor(hex: 0xFCF8F5)
        }
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
