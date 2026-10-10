import AppKit
import SwiftUI

/// The break (0022 §4): one black window per screen. The screen under the
/// mouse shows the pet, the countdown, a tip and (unless strict) the buttons.
@MainActor
final class EyeBreakOverlay {
    /// Spike S6 (0022 "Verified"): `.screenSaver` hid Force Quit, so the
    /// highest level that keeps it reachable and still covers the menu bar.
    static let windowLevel = NSWindow.Level.popUpMenu

    var onSkip: () -> Void = {}
    var onPostpone: () -> Void = {}
    /// Esc held for `EyeBreakPlanner.escHold` seconds: strict mode's way out.
    var onEscHeld: () -> Void = {}

    private var windows: [OverlayWindow] = []
    private var shown: (until: Date, tip: String, allowSkip: Bool)?
    private var escHold: DispatchWorkItem?

    var isVisible: Bool { !windows.isEmpty }

    func show(until: Date, tip: String, allowSkip: Bool, animate: Bool) {
        shown = (until, tip, allowSkip)
        build(animate: animate)
    }

    /// Screens came or went mid-break: one window per screen again.
    func rebuild() {
        guard isVisible else { return }
        build(animate: false)
        makeMainKey()
    }

    func makeMainKey() {
        windows.first(where: \.holdsCountdown)?.makeKeyAndOrderFront(nil)
    }

    func close(animate: Bool) {
        escHold?.cancel()
        escHold = nil
        shown = nil
        let closing = windows
        windows = []
        guard animate else {
            closing.forEach { $0.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 1
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated { closing.forEach { $0.orderOut(nil) } }
        })
    }

    private func build(animate: Bool) {
        guard let shown else { return }
        // The old key window's keyUp never arrives, so a pending hold would outlive the release.
        escHold?.cancel()
        escHold = nil
        windows.forEach { $0.orderOut(nil) }
        let screens = NSScreen.screens
        let main = EyeBreakLayout.mainIndex(screens: screens.map(\.frame), mouse: NSEvent.mouseLocation)
        windows = screens.enumerated().map { index, screen in
            let window = OverlayWindow(screen: screen, holdsCountdown: index == main)
            window.contentView = NSHostingView(rootView: BreakView(
                until: shown.until, tip: shown.tip, allowSkip: shown.allowSkip, holdsCountdown: index == main,
                onSkip: { [weak self] in self?.onSkip() }, onPostpone: { [weak self] in self?.onPostpone() }))
            window.onEsc = { [weak self] down, isRepeat in self?.esc(down: down, isRepeat: isRepeat, allowSkip: shown.allowSkip) }
            window.alphaValue = animate ? 0 : 1
            window.orderFrontRegardless()
            return window
        }
        guard animate else { return }
        let opening = windows
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            opening.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// Esc skips at once (key repeats ignored); in strict mode only a 3 s hold
    /// ends the break (§4). A repeat also starts the strict hold: activation can
    /// land late, so the first key-down may go to the app behind and the overlay
    /// then only sees repeats of a key that is already held.
    private func esc(down: Bool, isRepeat: Bool, allowSkip: Bool) {
        guard down else {
            escHold?.cancel()
            escHold = nil
            return
        }
        if allowSkip {
            if !isRepeat { onSkip() }
            return
        }
        guard escHold == nil else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onEscHeld() } }
        escHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EyeBreakPlanner.escHold, execute: work)
    }
}

/// Black, above full-screen apps, the menu bar and the Dock. Only the
/// countdown's window becomes key, so Esc reaches it and typing goes nowhere.
private final class OverlayWindow: NSWindow {
    let holdsCountdown: Bool
    var onEsc: (_ down: Bool, _ isRepeat: Bool) -> Void = { _, _ in }

    init(screen: NSScreen, holdsCountdown: Bool) {
        self.holdsCountdown = holdsCountdown
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = EyeBreakOverlay.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { holdsCountdown }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEsc(true, event.isARepeat) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 53 { onEsc(false, false) }
    }

    /// ⌘-shortcuts go nowhere during a break either.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}

private struct BreakView: View {
    let until: Date
    let tip: String
    let allowSkip: Bool
    let holdsCountdown: Bool
    let onSkip: () -> Void
    let onPostpone: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if holdsCountdown {
                VStack(spacing: 12) {
                    if let pet = Bundle.main.image(forResource: PetView.Pose.content.rawValue) {
                        Image(nsImage: pet)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 110)
                            .brightness(-0.12)
                            .opacity(0.9)
                            .accessibilityHidden(true)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = until.timeIntervalSince(context.date)
                        Text(EyeBreakText.clock(remaining))
                            .font(.system(size: 56, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(white: 0.93))
                            .accessibilityLabel("\(max(0, Int(remaining.rounded(.up)))) seconds left")
                    }
                    Text(tip)
                        .font(Theme.rounded(17, .medium))
                        .foregroundStyle(Color(white: 0.78))
                }
                if allowSkip {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Button("+5 min", action: onPostpone).accessibilityLabel("Postpone the eye break 5 minutes")
                            Button("Skip · esc", action: onSkip).accessibilityLabel("Skip the eye break")
                        }
                        .buttonStyle(DimButtonStyle())
                        .padding(.bottom, 36)
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Dim on black, so the buttons don't pull the eyes back to the screen.
private struct DimButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(13))
            .foregroundStyle(Color(white: configuration.isPressed ? 0.85 : 0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(white: 0.22)))
            .contentShape(Rectangle())
    }
}
