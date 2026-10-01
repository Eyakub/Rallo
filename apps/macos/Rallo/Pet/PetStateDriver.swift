import AppKit

/// Feeds the Rust pet reducer (docs/decisions/0006) and renders its
/// decision. Recomputes on change-revision changes, at the next reminder
/// deadline (one timer, no polling), when accessibility or pause settings
/// change, and after a one-off moment finishes.
@MainActor
final class PetStateDriver {
    private let core: CoreClient
    private let pet: PetController
    private let log: DiagnosticsLog
    private var watermarks = PetWatermarks()
    private var wasDue = false
    private var playing = false
    private var refreshAfterMoment = false
    private var dueTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Called when a reminder becomes due, so open views can show it.
    var onDueBoundary: () -> Void = {}

    init(core: CoreClient, pet: PetController, log: DiagnosticsLog) {
        self.core = core
        self.pet = pet
        self.log = log
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func refresh() {
        Task { await recompute() }
    }

    private func recompute() async {
        if playing {
            refreshAfterMoment = true
            return
        }
        do {
            let snapshot = try await core.petSnapshot()
            let paused = try await core.petAnimationsPaused()
            let seen = watermarks.seenValues(for: snapshot)
            let decision = decidePet(inputs: PetInputs(
                visible: pet.isVisible,
                reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                animationsPaused: paused,
                snapshot: snapshot,
                seenCompletionSeq: seen.completion,
                seenSaveSeq: seen.save,
                seenAgentWaitingSeq: seen.agentWaiting,
                wasDue: wasDue
            ))
            let newAgentWaiting = snapshot.agentWaitingSeq > seen.agentWaiting
            // Every event up to now is consumed by this decision, played or
            // not: a burst of saves becomes one acknowledgement, and work
            // finished while something is due is never celebrated later.
            watermarks.consume(snapshot)
            if newAgentWaiting {
                await announceNewlyWaitingAgent()
            }
            let becameDue = decision.pose == .due && !wasDue
            wasDue = decision.pose == .due
            armDueTimer(snapshot.nextDueAtMs)
            if becameDue { onDueBoundary() }
            render(decision, dueCount: Int(snapshot.dueCount), agentsWaiting: Int(snapshot.agentsWaiting))
        } catch {
            log.record("pet_state_failed", ["error": "\(error)"])
        }
    }

    private func render(_ decision: PetDecision, dueCount: Int, agentsWaiting: Int) {
        guard decision.pose != .hidden else { return }
        let pose: PetView.Pose = switch decision.pose {
        case .due: .nudge
        case .sleeping: .sleep
        case .idle, .hidden: .idle
        }
        let moment: PetView.Moment = switch decision.event {
        case .none: .none
        case .attention: .attention
        case .celebrate: .celebrate
        case .acknowledge: .acknowledge
        }
        playing = moment != .none
        pet.apply(pose: pose, moment: moment, animate: decision.animate, ambient: decision.ambient,
                  dueCount: dueCount, agentsWaiting: agentsWaiting, label: decision.accessibilityLabel) { [weak self] in
            guard let self else { return }
            self.playing = false
            if self.refreshAfterMoment {
                self.refreshAfterMoment = false
                self.refresh()
            }
        }
    }

    /// VoiceOver announcement for a new waiting agent (0008): "Claude Code in
    /// shop is waiting for permission: Bash." The most recently updated
    /// waiting session is the one that just crossed the watermark.
    private func announceNewlyWaitingAgent() async {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        guard let sessions = try? await core.agentSessions(),
              let session = AgentSessionFormatting.sorted(sessions).first(where: { $0.state == "waiting" })
        else { return }
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: AgentSessionFormatting.waitingAnnouncement(for: session),
                       .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// The next deadline is the only time the base state changes without a
    /// write, so one timer covers it.
    private func armDueTimer(_ nextDueAtMs: Int64?) {
        dueTimer?.invalidate()
        dueTimer = nil
        guard let nextDueAtMs else { return }
        let interval = max(0.05, TimeInterval(nextDueAtMs) / 1000 - Date().timeIntervalSince1970 + 0.05)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        dueTimer = timer
    }
}
