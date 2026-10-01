import AppKit
import SwiftUI

/// The standard Settings window (⌘,): native toolbar tabs, one window kept
/// in memory and brought forward on later opens. The window title follows
/// the selected tab, as in other Mac apps.
@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.opened()
        let window = window ?? makeWindow()
        self.window = window
        if let index = SettingsTab.allCases.firstIndex(where: { $0.rawValue == model.tab }) {
            tabs?.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let page = NSHostingController(rootView: tab.view(model))
            page.sizingOptions = [.preferredContentSize]
            page.title = tab.title  // the window title follows the selected tab
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsTab.size)
        window.center()
        return window
    }
}
