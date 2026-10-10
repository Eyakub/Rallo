import AppKit
import SwiftUI

/// What the bubble's buttons do, for the alert it shows (0021 §3).
struct SummonBubbleActions {
    var done: (String) -> Void = { _ in }
    /// `nil`: the 10-minute snooze; otherwise a panel preset.
    var snooze: (String, RemindPreset?) -> Void = { _, _ in }
    var open: (String) -> Void = { _ in }
    var jump: (String) -> Void = { _ in }
    var later: (String) -> Void = { _ in }
    var more: () -> Void = {}
}

struct SummonBubbleView: View {
    let alertID: String
    let content: SummonBubbleContent
    let actions: SummonBubbleActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(content.kindLine)
                    .font(Theme.rounded(11, .semibold))
                    .foregroundStyle(Theme.rust)
                Spacer(minLength: 8)
                if content.moreCount > 0 {
                    Button(action: actions.more) {
                        Text("+\(content.moreCount) more")
                            .font(Theme.rounded(11, .semibold))
                            .foregroundStyle(Theme.rust)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(content.moreCount) more alerts")
                }
            }
            if let text = content.text {
                Text(text)
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if content.isAgent {
                    Button("Jump to it") { actions.jump(alertID) }
                        .buttonStyle(BubbleButtonStyle(primary: true))
                    Button("Later") { actions.later(alertID) }
                        .buttonStyle(BubbleButtonStyle(primary: false))
                } else {
                    Button("Done") { actions.done(alertID) }
                        .buttonStyle(BubbleButtonStyle(primary: true))
                    Menu {
                        ForEach(RemindPreset.allCases) { preset in
                            Button(preset.title) { actions.snooze(alertID, preset) }
                        }
                    } label: {
                        Text("Snooze 10 min \u{25BE}").bubbleChrome(primary: false)
                    } primaryAction: {
                        actions.snooze(alertID, nil)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Snooze 10 min")
                    .fixedSize()
                    Button("Open") { actions.open(alertID) }
                        .buttonStyle(BubbleButtonStyle(primary: false))
                }
            }
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .tint(Theme.rust)
    }
}

/// The mockup's bubble buttons (docs/mockups/reminder-attention.html): a
/// system prominent button renders grey in a panel that never becomes key.
private struct BubbleButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .bubbleChrome(primary: primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private extension View {
    func bubbleChrome(primary: Bool) -> some View {
        font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(primary ? Theme.onRust : Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(primary ? Theme.rust : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(primary ? Theme.rust : Theme.fieldStroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The bubble's window: takes clicks, never keyboard focus (0021 §11).
final class SummonBubblePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        canHide = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Lays the bubble out 12 pt above `petFrame`, kept on that display.
    func show(_ view: SummonBubbleView, above petFrame: NSRect) {
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        host.setFrameSize(size)
        contentView = host
        var origin = NSPoint(x: petFrame.midX - size.width / 2, y: petFrame.maxY + 12)
        if let area = (NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
            origin.y = min(origin.y, area.maxY - size.height - 8)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}

/// A click in a panel that never becomes key still reaches the buttons.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
