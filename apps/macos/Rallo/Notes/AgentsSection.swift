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

/// The panel's "Agents" section, listed above the notes when Rallo is
/// tracking any Claude Code/Codex session (docs/decisions/0007).
struct AgentsSection: View {
    let sessions: [AgentSessionSnapshot]
    let now: Date
    let onActivate: (AgentSessionSnapshot) -> Void
    let onDismiss: (AgentSessionSnapshot) -> Void

    private var ordered: [AgentSessionSnapshot] { AgentSessionFormatting.sorted(sessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents")
                .font(Theme.rounded(12, .semibold))
                .foregroundStyle(Theme.bark)
                .padding(.horizontal, 20)
            VStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.rowID) { index, session in
                    if index > 0 {
                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 44).padding(.trailing, 10)
                    }
                    AgentRow(session: session, now: now, onActivate: { onActivate(session) },
                             onDismiss: { onDismiss(session) })
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hover))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.fieldStroke))
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }
}

private struct AgentRow: View {
    let session: AgentSessionSnapshot
    let now: Date
    let onActivate: () -> Void
    let onDismiss: () -> Void
    @State private var hovering = false

    private static let accent = Color(nsColor: NSColor(hex: 0x2F6FB0))
    private var waiting: Bool { session.state == "waiting" }
    private var clickable: Bool { session.appPath != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal")
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
        .onHover { hovering = clickable && $0 }
        .onTapGesture { if clickable { onActivate() } }
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if waiting {
                    Circle().fill(Self.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.bark)
                        .accessibilityHidden(true)
                }
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
