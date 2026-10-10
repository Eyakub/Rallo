import Foundation

extension AlertSettings {
    /// The core's defaults (0021 §7), used until the first read.
    static let initial = AlertSettings(summon: true, sound: .ralloChime, nag: true, nagIntervalMinutes: 2,
                                       nagMaxRounds: 5, glow: false, agents: true)
}

/// One thing to notice (0021 §1): a due reminder or a long-waiting agent.
struct AttentionAlert: Equatable {
    enum Kind: Equatable {
        case reminder(deadline: Date)
        case agent(waitingSince: Date)
    }

    /// The note's id, or the long-wait notification's identifier.
    let id: String
    let kind: Kind
    /// The note's text, or "Claude Code is waiting in rallo".
    let text: String
    /// Launch and wake groups get one round and never nag (§2).
    var nags: Bool
    /// Nag repeats already run for this alert; the first round isn't one.
    var repeats = 0
}

/// What holds a round back or changes it (§8).
struct AttentionSignals: Equatable {
    var focusOn = false
    var cameraOrMicInUse = false
    var eyeBreakActive = false
    /// Reduce Motion, or the menu's Pause Animations.
    var reduceMotion = false
}

/// One round's effects (§3).
struct AttentionRound: Equatable {
    var summon: Bool
    var glow: Bool
    /// The in-app chime; a first round's sound is the banner's own.
    var chime: Bool
    /// False in a call: no note text, repo, or time.
    var showsDetails: Bool
    /// Reduce Motion: fades instead of the hop and the pulses.
    var fades: Bool
    /// The bubble's order: newest first.
    var alertIDs: [String]
}

/// Pending alerts and the due reminders already seen (§2, §4, §5). Only
/// `handle` and a due-list change remove an alert: a round, a nag, or the
/// bubble timing out never does.
struct AttentionQueue: Equatable {
    /// Oldest first.
    private(set) var alerts: [AttentionAlert] = []
    /// Due reminder ids seen so far (alerted, or seeded at launch and wake).
    private(set) var alertedReminders: Set<String> = []

    /// Records the due list and returns the ids that just came due. An id
    /// that left the list is handled and forgotten, so it can alert again.
    mutating func dueListChanged(_ due: [String]) -> [String] {
        let dueSet = Set(due)
        let gone = alertedReminders.subtracting(dueSet)
        let new = due.filter { !alertedReminders.contains($0) }
        alertedReminders.subtract(gone)
        alertedReminders.formUnion(new)
        alerts.removeAll { gone.contains($0.id) }
        return new
    }

    mutating func add(_ alert: AttentionAlert) {
        guard !alerts.contains(where: { $0.id == alert.id }) else { return }
        alerts.append(alert)
    }

    mutating func handle(_ id: String) {
        alerts.removeAll { $0.id == id }
    }

    /// The alert a nag round re-rings: the newest one with a repeat left, of
    /// either kind. A launch or wake group (§2) never re-rings. Read before
    /// `countNag`, which may use up that alert's last repeat.
    func drivingAlert(maxRounds: Int) -> AttentionAlert? {
        alerts.last { $0.nags && $0.repeats < maxRounds }
    }

    /// A nag round ran: one repeat for every alert that still had one.
    mutating func countNag(maxRounds: Int) {
        for index in alerts.indices where alerts[index].nags && alerts[index].repeats < maxRounds {
            alerts[index].repeats += 1
        }
    }
}

/// Decides rounds (0021 §3, §4, §8); `AttentionCoordinator` performs them.
enum AttentionPlanner {
    enum RoundKind: Equatable {
        /// The trigger itself: the banner rings, so no in-app chime.
        case first
        case nag
        /// A round that waited for a Focus or an eye break to end.
        case resumed
    }

    enum Decision: Equatable {
        case run(AttentionRound)
        case hold
        case nothing
    }

    /// Launch (§2): due reminders from the last 12 hours get one grouped round.
    static let launchWindow: TimeInterval = 12 * 60 * 60

    static func decide(_ kind: RoundKind, settings: AlertSettings, signals: AttentionSignals,
                       alerts: [AttentionAlert]) -> Decision {
        guard !alerts.isEmpty, settings.summon || settings.glow || settings.nag else { return .nothing }
        if signals.focusOn || signals.eyeBreakActive { return .hold }
        let inCall = signals.cameraOrMicInUse
        return .run(AttentionRound(
            summon: settings.summon,
            glow: settings.glow,
            chime: kind != .first && settings.sound != AlertSound.none && !inCall,
            showsDetails: !inCall,
            fades: signals.reduceMotion,
            alertIDs: alerts.reversed().map(\.id)
        ))
    }

    /// When the next nag round is due, or nil when nothing has a repeat left.
    static func nextNag(after lastRound: Date, settings: AlertSettings, alerts: [AttentionAlert]) -> Date? {
        guard settings.nag,
              alerts.contains(where: { $0.nags && $0.repeats < Int(settings.nagMaxRounds) }) else { return nil }
        return lastRound.addingTimeInterval(TimeInterval(settings.nagIntervalMinutes) * 60)
    }

    /// Launch and wake (§2): of the reminders that just came due, those
    /// due at or after `cutoff` get one grouped round.
    static func grouped(_ due: [(id: String, deadline: Date)], cutoff: Date) -> [String] {
        due.filter { $0.deadline >= cutoff }.map(\.id)
    }
}
