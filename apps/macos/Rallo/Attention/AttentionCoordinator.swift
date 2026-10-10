import AppKit

/// Reminder and agent alerts (0021): takes the triggers, keeps the queue,
/// asks `AttentionPlanner` what a round does, and performs it. Owns the nag
/// timer and the once-a-minute re-check of a held round.
@MainActor
final class AttentionCoordinator {
    /// How a nag round sounds. Spike S1 decides; Task 11a changes only this.
    enum NagSoundRoute { case inApp, renotify, silent }
    static let nagSoundRoute = NagSoundRoute.inApp

    private let core: CoreClient
    private let quietSignals: QuietSignals
    private let log: DiagnosticsLog
    private let summon: SummonController
    private let glow = EdgeGlowController()
    private var queue = AttentionQueue()
    private var settings = AlertSettings.initial
    /// The latest due notes by id, for the bubble's actions.
    private var dueItems: [String: ItemSnapshot] = [:]
    private var agentSessions: [String: AgentSessionSnapshot] = [:]
    private var seeded = false
    private var sleptAt: Date?
    /// A grouping cutoff whose refresh failed, carried to the next one.
    private var pendingCutoff: Date?
    private var refreshTask: Task<Void, Never>?
    private var lastRoundAt: Date?
    private var lastRound: AttentionRound?
    private var heldRound: AttentionPlanner.RoundKind?
    private var nagTimer: Timer?
    private var holdTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Set by plan 2. While it returns true, rounds wait (0021 §8).
    var eyeBreakActive: () -> Bool = { false }
    /// True while the summon bubble is on screen.
    private(set) var isBubbleVisible = false {
        didSet { if isBubbleVisible != oldValue { onBubbleVisibilityChanged(isBubbleVisible) } }
    }
    /// Fires on every change of `isBubbleVisible`; plan 2 holds a break while true.
    var onBubbleVisibilityChanged: (Bool) -> Void = { _ in }
    /// The menu's Pause Animations, treated like Reduce Motion (§8).
    var animationsPaused: () -> Bool = { false }
    var openNotes: (String?) -> Void = { _ in }
    var activateAgent: (AgentSessionSnapshot) -> Void = { _ in }
    /// Task 11a only: re-adds a reminder's delivered banner so a Focus can mute it.
    var renotify: (String) -> Void = { _ in }

    init(core: CoreClient, pet: PetController, quietSignals: QuietSignals, log: DiagnosticsLog) {
        self.core = core
        self.quietSignals = quietSignals
        self.log = log
        summon = SummonController(pet: pet)
        summon.onClosed = { [weak self] in self?.isBubbleVisible = false }
        summon.actions = SummonBubbleActions(
            done: { [weak self] id in self?.complete(id) },
            snooze: { [weak self] id, preset in self?.snooze(id, preset) },
            open: { [weak self] id in self?.open(id) },
            jump: { [weak self] id in self?.jump(id) },
            later: { [weak self] id in self?.handle(id) },
            more: { [weak self] in self?.openNotes(nil) }
        )
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleptAt = Date() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dueMayHaveChanged() }
        })
    }

    // MARK: Triggers (0021 §2)

    func settingsChanged(_ settings: AlertSettings) {
        self.settings = settings
        if !settings.agents {
            for alert in queue.alerts { if case .agent = alert.kind { queue.handle(alert.id) } }
            agentSessions = [:]
            queueChanged()
        } else if heldRound == nil {
            armNag()
        }
    }

    /// Every `PetStateDriver` recompute: diff the due list. The first one
    /// after launch, and the first after a wake, group what came due. Wake
    /// may reach here before the didWake observer, so `sleptAt` is consumed by
    /// whichever trigger comes first.
    func dueMayHaveChanged() {
        var cutoff = seeded ? sleptAt : Date().addingTimeInterval(-AttentionPlanner.launchWindow)
        if let pendingCutoff { cutoff = min(cutoff ?? pendingCutoff, pendingCutoff) }
        pendingCutoff = nil
        seeded = true
        sleptAt = nil
        let previous = refreshTask
        refreshTask = Task { [weak self] in
            await previous?.value
            await self?.refreshDue(groupFrom: cutoff)
        }
    }

    /// `AgentWaitNotifier` posted a long-wait alert (0008).
    func agentPosted(_ session: AgentSessionSnapshot, identifier: String) {
        guard settings.agents else { return }
        agentSessions[identifier] = session
        let since = Date(timeIntervalSince1970: TimeInterval(session.updatedAtMs) / 1000)
        queue.add(AttentionAlert(id: identifier, kind: .agent(waitingSince: since),
                                 text: SummonBubbleContent.agentText(for: session), nags: true))
        run(.first)
    }

    /// The sessions behind these long-wait alerts stopped waiting (§4).
    func agentsWithdrawn(_ identifiers: [String]) {
        for identifier in identifiers {
            queue.handle(identifier)
            agentSessions[identifier] = nil
        }
        queueChanged()
    }

    /// A click on a reminder banner opens the note: handled (§4).
    func bannerOpened(itemID: String?) {
        guard let itemID else { return }
        handle(itemID)
    }

    /// A click on a long-wait banner jumps to the agent: handled (§4).
    func bannerActivatedAgent(agent: String, sessionId: String) {
        for (identifier, session) in agentSessions where session.agent == agent && session.sessionId == sessionId {
            queue.handle(identifier)
            agentSessions[identifier] = nil
        }
        queueChanged()
    }

    /// Plan 2 calls this when a break ends; a waiting round runs then.
    func eyeBreakEnded() {
        if let heldRound { run(heldRound) }
    }

    private func refreshDue(groupFrom cutoff: Date?) async {
        let items: [ItemSnapshot]
        do {
            items = try await core.allDueItems()
        } catch {
            log.record("attention_due_failed", ["error": "\(error)"])
            // Keep the grouping cutoff for the next refresh (§2): a failed read must not turn old reminders into nags.
            if let cutoff { pendingCutoff = min(pendingCutoff ?? cutoff, cutoff) }
            return
        }
        dueItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let new = Set(queue.dueListChanged(items.map(\.id)))
        var alerted = items.filter { new.contains($0.id) }
        if let cutoff {
            let group = Set(AttentionPlanner.grouped(alerted.map { (id: $0.id, deadline: $0.reminder?.deadline ?? .distantPast) },
                                                     cutoff: cutoff))
            alerted = alerted.filter { group.contains($0.id) }
        }
        for item in alerted {
            queue.add(AttentionAlert(id: item.id, kind: .reminder(deadline: item.reminder?.deadline ?? Date()),
                                     text: item.text, nags: cutoff == nil))
        }
        if alerted.isEmpty { queueChanged() } else { run(.first) }
    }

    // MARK: Rounds (§3, §4, §8)

    private func run(_ kind: AttentionPlanner.RoundKind) {
        let signals = AttentionSignals(
            focusOn: quietSignals.focusOn,
            cameraOrMicInUse: quietSignals.cameraOrMicInUse,
            eyeBreakActive: eyeBreakActive(),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || animationsPaused()
        )
        switch AttentionPlanner.decide(kind, settings: settings, signals: signals, alerts: queue.alerts) {
        case .nothing:
            heldRound = nil
            holdTimer?.invalidate()
            holdTimer = nil
        case .hold:
            heldRound = .resumed
            log.record("attention_held", ["alerts": queue.alerts.count, "focus": signals.focusOn,
                                          "eye_break": signals.eyeBreakActive])
            armHoldCheck()
            return
        case let .run(round):
            heldRound = nil
            holdTimer?.invalidate()
            holdTimer = nil
            if kind != .first { queue.countNag(maxRounds: Int(settings.nagMaxRounds)) }
            lastRoundAt = Date()
            // Counts and switches only: diagnostics never carry note text.
            log.record("attention_round", ["kind": "\(kind)", "alerts": queue.alerts.count, "summon": round.summon,
                                           "glow": round.glow, "chime": round.chime, "details": round.showsDetails])
            perform(round)
        }
        armNag()
    }

    private func perform(_ round: AttentionRound) {
        lastRound = round
        if round.chime { chime() }
        if round.glow { glow.pulse(fades: round.fades) }
        if round.summon { showBubble(for: round) }
    }

    private func showBubble(for round: AttentionRound) {
        guard let first = round.alertIDs.first, let alert = queue.alerts.first(where: { $0.id == first }) else {
            return summon.dismiss()
        }
        let content = SummonBubbleContent.make(for: alert, showsDetails: round.showsDetails,
                                               moreCount: round.alertIDs.count - 1, now: Date())
        if summon.present(alertID: alert.id, content: content, fades: round.fades) { isBubbleVisible = true }
    }

    /// After an alert was handled: the bubble moves to the next one, or closes.
    private func queueChanged() {
        guard !queue.alerts.isEmpty else {
            nagTimer?.invalidate()
            nagTimer = nil
            holdTimer?.invalidate()
            holdTimer = nil
            heldRound = nil
            summon.dismiss()
            return
        }
        // Re-show only when the list changed: presenting restarts the 60 s timeout.
        let ids = queue.alerts.reversed().map(\.id)
        if summon.isPresented, var round = lastRound, round.alertIDs != ids {
            round.alertIDs = ids
            lastRound = round
            showBubble(for: round)
        }
        if heldRound == nil { armNag() }
    }

    private func chime() {
        switch Self.nagSoundRoute {
        case .inApp:
            settings.sound.play()
        case .renotify:
            if let reminder = queue.alerts.last(where: { if case .reminder = $0.kind { true } else { false } }) {
                renotify(reminder.id)
            }
        case .silent:
            break
        }
    }

    private func armNag() {
        nagTimer?.invalidate()
        nagTimer = nil
        guard let lastRoundAt,
              let next = AttentionPlanner.nextNag(after: lastRoundAt, settings: settings, alerts: queue.alerts) else { return }
        let timer = Timer(timeInterval: max(1, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.run(.nag) }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        nagTimer = timer
    }

    /// A held round is re-checked once a minute: a Focus may have ended (§9).
    private func armHoldCheck() {
        nagTimer?.invalidate()
        nagTimer = nil
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let held = self.heldRound else { return }
                self.run(held)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    // MARK: Bubble actions (§3, §4)

    private func handle(_ id: String) {
        queue.handle(id)
        agentSessions[id] = nil
        queueChanged()
    }

    private func complete(_ id: String) {
        guard let item = dueItems[id] else { return handle(id) }
        handle(id)
        Task {
            do { _ = try await core.completeItem(item) } catch { failed(id, error) }
        }
    }

    /// `nil`: the banner's 10 minutes; a preset applies as the panel applies it.
    private func snooze(_ id: String, _ preset: RemindPreset?) {
        guard let item = dueItems[id] else { return handle(id) }
        handle(id)
        Task {
            do {
                switch preset {
                case nil: _ = try await core.snoozeReminder(item, duration: "10m")
                case .inTwentyMinutes?: _ = try await core.remindIn(item, duration: "20m")
                case .inOneHour?: _ = try await core.remindIn(item, duration: "1h")
                case .tomorrowMorning?: _ = try await core.remindAt(item, date: RemindPreset.tomorrowMorning())
                }
            } catch {
                failed(id, error)
            }
        }
    }

    private func open(_ id: String) {
        handle(id)
        openNotes(id)
    }

    private func jump(_ id: String) {
        let session = agentSessions[id]
        handle(id)
        if let session { activateAgent(session) }
    }

    /// The note changed elsewhere first: show it as it is now, like a stale banner action.
    private func failed(_ id: String, _ error: Error) {
        log.record("attention_action_failed", ["item_id": id, "error": "\(error)"])
        openNotes(id)
    }
}
