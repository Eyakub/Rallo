import AppKit
import SwiftUI

@MainActor
private final class BubbleModel: ObservableObject {
    @Published var text = ""
    @Published var listening = false
}

private struct BubbleView: View {
    @ObservedObject var model: BubbleModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.listening {
                Circle().fill(Theme.error).frame(width: 8, height: 8).padding(.top, 5)
            }
            Text(model.text)
                .font(Theme.rounded(13, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(4)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.divider))
        .fixedSize()
    }
}

/// Never key, never main: it must not take focus from the app being typed into.
private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The small bubble above the pet that shows live voice-typing text (0013).
@MainActor
final class VoiceBubble {
    private let model = BubbleModel()
    private let panel: NSPanel
    private let host: NSHostingView<BubbleView>
    /// The pet's frame, or nil while the pet is hidden.
    var petFrame: () -> NSRect? = { nil }

    init() {
        host = NSHostingView(rootView: BubbleView(model: model))
        panel = BubblePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Same level and collection behaviour as the pet (0002).
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
    }

    func show(_ text: String, listening: Bool) {
        model.text = text
        model.listening = listening
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    private func origin(for size: NSSize) -> NSPoint {
        if let pet = petFrame() {
            let screen = NSScreen.screens.first { $0.frame.intersects(pet) } ?? NSScreen.main
            var p = NSPoint(x: pet.midX - size.width / 2, y: pet.maxY + 6)
            if let v = screen?.visibleFrame {
                p.x = min(max(p.x, v.minX + 4), v.maxX - size.width - 4)
                p.y = min(p.y, v.maxY - size.height - 4)
            }
            return p
        }
        let v = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16)
    }
}
