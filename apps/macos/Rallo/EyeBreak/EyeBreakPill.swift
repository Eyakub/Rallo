import AppKit
import SwiftUI

/// Never key, never main: the pill and the toast must not take focus (0022 §3, §5).
private final class QuietPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Same level and collection behaviour as the pet and the voice bubble (0002).
@MainActor
private func makePanel(clickable: Bool) -> NSPanel {
    let panel = QuietPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = !clickable
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    return panel
}

@MainActor
private final class PillModel: ObservableObject {
    @Published var until = Date()
    @Published var total: TimeInterval = 10
}

private struct PillView: View {
    @ObservedObject var model: PillModel
    let onStartNow: () -> Void
    let onPostpone: () -> Void
    let onSkip: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, model.until.timeIntervalSince(context.date))
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Theme.onToast.opacity(0.2), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: model.total > 0 ? remaining / model.total : 0)
                        .stroke(Theme.toastAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                Text(EyeBreakText.pill(remaining)).font(Theme.rounded(13, .semibold))
                Button("Start now", action: onStartNow)
                Button("+5 min", action: onPostpone)
                Button("Skip", action: onSkip)
            }
            .buttonStyle(PillButtonStyle())
            .foregroundStyle(Theme.onToast)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Theme.toast, in: Capsule())
            .fixedSize()
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(12, .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.onToast.opacity(configuration.isPressed ? 0.24 : 0.12), in: Capsule())
            .contentShape(Capsule())
    }
}

/// The warning before a break (0022 §3), top centre of the screen under the mouse.
@MainActor
final class EyeBreakPill {
    var onStartNow: () -> Void = {}
    var onPostpone: () -> Void = {}
    var onSkip: () -> Void = {}

    private let model = PillModel()
    private let panel = makePanel(clickable: true)
    private lazy var host = FirstClickHostingView(rootView: PillView(
        model: model,
        onStartNow: { [weak self] in self?.onStartNow() },
        onPostpone: { [weak self] in self?.onPostpone() },
        onSkip: { [weak self] in self?.onSkip() }))

    func show(until: Date, total: TimeInterval, on screen: NSScreen?) {
        model.until = until
        model.total = total
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 8))
        panel.orderFrontRegardless()
    }

    /// Detaching the host stops its once-a-second TimelineView while hidden.
    func hide() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            if let pet = Bundle.main.image(forResource: PetView.Pose.happy.rawValue) {
                Image(nsImage: pet).resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
            }
            Text(text).font(Theme.rounded(12.5, .semibold))
        }
        .foregroundStyle(Theme.onToast)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.toast, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize()
    }
}

/// "Eyes rested · next in 20 min" (0022 §5), above the pet, for 3 s.
@MainActor
final class EyeBreakToast {
    private let panel = makePanel(clickable: false)
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, near petFrame: NSRect?) {
        let host = NSHostingView(rootView: ToastView(text: text))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, petFrame: petFrame))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.orderOut(nil) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Above the pet like the voice bubble, else the top-right corner.
    private func origin(for size: NSSize, petFrame: NSRect?) -> NSPoint {
        if let pet = petFrame {
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
