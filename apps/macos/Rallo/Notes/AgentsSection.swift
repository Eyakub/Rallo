import AppKit
import SwiftUI

/// Ticks `now` every 30 s while something observes it, for the Agents
/// section's relative times; started/stopped with the panel (NotesView).
@MainActor
final class AgentsClock: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        now = Date()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Swiping a row sideways dismisses it, like a notification (0010): a
/// two-finger trackpad swipe or a click-drag past `threshold`; anything
/// shorter springs back. The ✕ stays for the keyboard and VoiceOver.
@MainActor
final class RowSwipe: ObservableObject {
    static let threshold: CGFloat = 90
    @Published private(set) var offset: CGFloat = 0
    var pointerInside = false
    var reduceMotion = false
    var onDismiss: () -> Void = {}

    private enum Phase { case idle, deciding, tracking, ignoring }
    private var phase = Phase.idle
    private var swallowMomentum = false
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        // Local monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let event = event
            let swallow = MainActor.assumeIsolated { self?.consume(event) == true }
            return swallow ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func drag(_ width: CGFloat) { offset = width }
    func dragEnded() { finish() }

    /// Whether `event` belongs to a sideways swipe on this row; vertical
    /// scrolling and mouse wheels pass through to the scroll view.
    private func consume(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty {
            let swallow = swallowMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowMomentum = false }
            return swallow
        }
        guard event.hasPreciseScrollingDeltas else { return false }
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if event.phase.contains(.began) {
            phase = pointerInside ? .deciding : .ignoring
            return false
        }
        switch phase {
        case .deciding:
            guard !ended else { phase = .idle; return false }
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return false }
            phase = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .tracking : .ignoring
            return phase == .tracking && move(event)
        case .tracking:
            guard !ended else {
                phase = .idle
                swallowMomentum = true
                finish()
                return true
            }
            return move(event)
        case .idle, .ignoring:
            if ended { phase = .idle }
            return false
        }
    }

    /// Follows the fingers whether or not "natural" scrolling is on.
    private func move(_ event: NSEvent) -> Bool {
        offset += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        return true
    }

    private func finish() {
        guard abs(offset) > Self.threshold else {
            animate { self.offset = 0 }
            return
        }
        let away: CGFloat = offset > 0 ? 420 : -420
        animate { self.offset = away }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.15)) { self.onDismiss() }
    }

    private func animate(_ change: @escaping () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.15), change) }
    }
}

/// The panel's agents section, above the notes while any Claude Code/Codex/Grok
/// session waits on the user (docs/decisions/0007). Capped in height and
/// scrollable, so the composer and notes always stay in view.
struct AgentsSection: View {
    let sessions: [AgentSessionSnapshot]
    let now: Date
    let onActivate: (AgentSessionSnapshot) -> Void
    let onDismiss: (AgentSessionSnapshot) -> Void

    private var ordered: [AgentSessionSnapshot] { AgentSessionFormatting.sorted(sessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Waiting for you")
                .font(Theme.rounded(12, .semibold))
                .foregroundStyle(Theme.bark)
                .padding(.horizontal, 20)
            // Natural height while it fits, a scroll view beyond that.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
            .frame(maxHeight: 160)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.fieldStroke))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.rowID) { index, session in
                if index > 0 {
                    Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 44).padding(.trailing, 10)
                }
                AgentRow(session: session, now: now, onActivate: { onActivate(session) },
                         onDismiss: { onDismiss(session) })
            }
        }
    }
}

private struct AgentRow: View {
    let session: AgentSessionSnapshot
    let now: Date
    let onActivate: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false
    @StateObject private var swipe = RowSwipe()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let accent = Color(nsColor: NSColor(hex: 0x2F6FB0))
    private var clickable: Bool { session.isActionable }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: session.isClickUp ? "bubble.left" : "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.bark)
                .frame(width: 20, height: 20)
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AgentSessionFormatting.accessibilityLabel(for: session, now: now))
                .accessibilityAddTraits(clickable ? .isButton : [])
                .accessibilityHint(clickable ? "" : "Rallo couldn’t identify this agent’s terminal")
                .accessibilityAction { if clickable { onActivate() } }
            Spacer(minLength: 4)
            Text(AgentSessionFormatting.relativeTime(updatedAtMs: session.updatedAtMs, now: now))
                .font(Theme.rounded(11))
                .foregroundStyle(Theme.bark)
                .accessibilityHidden(true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.bark)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering && clickable ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .offset(x: swipe.offset)
        .opacity(1 - min(abs(swipe.offset) / 240, 0.7))
        .onHover { inside in
            hovering = clickable && inside
            swipe.pointerInside = inside
        }
        .onTapGesture { if clickable { onActivate() } }
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { swipe.drag($0.translation.width) }
            .onEnded { _ in swipe.dragEnded() })
        .onAppear {
            swipe.onDismiss = onDismiss
            swipe.reduceMotion = reduceMotion
            swipe.install()
        }
        .onDisappear { swipe.remove() }
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Self.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(AgentSessionFormatting.title(for: session))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            Text(AgentSessionFormatting.subtitle(for: session))
                .font(Theme.rounded(12))
                .foregroundStyle(Theme.bark)
                .lineLimit(1)
        }
    }
}
