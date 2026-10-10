import Foundation

/// The 20-20-20 eye-break cycle (0022) as a pure value: no timers, windows
/// or system calls. `EyeBreakController` feeds it the clock, idle time and
/// events, shows what `phase` says, and calls `tick` again at `nextCheck`.
struct EyeBreakPlanner: Equatable {
    /// In seconds; from the stored preference by `init(_:intervalOverride:)`.
    struct Settings: Equatable {
        var enabled = false
        var interval: TimeInterval = 20 * 60
        var length: TimeInterval = 20
        /// 0: no warning, the break starts at once (§3).
        var warning: TimeInterval = 10
        var allowSkip = true
        var holdOnCall = true
    }

    enum Phase: Equatable {
        case off
        /// Screen time counts toward the next break.
        case counting
        /// Locked, or the displays or the Mac asleep: nothing counts (§2).
        case away
        /// The menu's Pause Eye Breaks (§7).
        case paused(until: Date)
        /// Due, but a call or a reminder bubble holds it (§6).
        case held
        case warning(until: Date)
        case breaking(until: Date)
    }

    /// What can hold a due break (§6), read at every tick.
    struct Hold: Equatable {
        var callActive = false
        var bubbleVisible = false
    }

    /// The menu's status line (§7).
    enum MenuStatus: Equatable {
        case off
        case due(in: TimeInterval)
        case paused(until: Date)
        /// Held by a call or a reminder bubble.
        case waiting
    }

    static let naturalBreak: TimeInterval = 5 * 60
    static let postponement: TimeInterval = 5 * 60
    static let escHold: TimeInterval = 3
    /// The longest gap between ticks: idle time and calls are read once a minute (§2, §6).
    static let tickCap: TimeInterval = 60
    static let tips = ["Look at something far away", "Blink slowly", "Look out the window"]

    private(set) var settings: Settings
    private(set) var phase: Phase
    /// Where the current stretch of screen time started.
    private(set) var cycleStart: Date
    /// After +5 min (§4): the break is due here, not a full cycle after `cycleStart`.
    private(set) var postponedDue: Date?
    /// Idle for `naturalBreak` was seen; the cycle restarts when the user is back.
    private(set) var awaitingReturn = false
    private(set) var breaksTaken = 0
    /// False while locked or asleep, whatever the phase: a pause that runs out or
    /// turning on must not start counting on an unavailable screen.
    private(set) var screenAvailable = true

    init(settings: Settings, now: Date) {
        self.settings = settings
        phase = settings.enabled ? .counting : .off
        cycleStart = now
    }

    /// The tip for the current or next break; it rotates each break (§4).
    var tip: String { Self.tips[breaksTaken % Self.tips.count] }

    var breakDue: Date { postponedDue ?? cycleStart.addingTimeInterval(settings.interval) }

    /// Turning on or off, or a new interval, starts a fresh cycle (§2); other changes apply as they are.
    mutating func apply(_ new: Settings, now: Date) {
        let restart = new.enabled != settings.enabled || new.interval != settings.interval
        settings = new
        guard restart else { return }
        restartCycle(now)
        if !new.enabled {
            phase = .off
        } else if phase == .off || isActive {
            phase = screenAvailable ? .counting : .away
        }
    }

    /// Lock, display sleep or system sleep (false), and the way back (true) (§2).
    mutating func setScreenAvailable(_ available: Bool, now: Date) {
        screenAvailable = available
        guard settings.enabled else { return }
        if !available {
            if case .paused = phase { return }
            phase = .away
        } else if phase == .away {
            restartCycle(now)
            phase = .counting
        }
    }

    /// The timer fired, at `nextCheck` or late. `idle` is seconds since the last input.
    mutating func tick(now: Date, idle: TimeInterval, hold: Hold) {
        if now < cycleStart { restartCycle(now) }  // the clock went back
        switch phase {
        case .off, .away:
            return
        case let .paused(until):
            guard now >= until else { return }
            restartCycle(now)
            phase = screenAvailable ? .counting : .away
        case .counting, .held:
            if idle >= Self.naturalBreak {
                awaitingReturn = true
                phase = .counting
                return
            }
            if awaitingReturn {
                restartCycle(now.addingTimeInterval(-idle))
                return
            }
            guard phase == .held || now >= breakDue.addingTimeInterval(-settings.warning) else { return }
            if isHeld(hold) {
                phase = .held
            } else {
                beginWarning(now)
            }
        case let .warning(until):
            if isHeld(hold) {
                phase = .held
            } else if now >= until || until.timeIntervalSince(now) > settings.warning {
                beginBreak(now)
            }
        case let .breaking(until):
            if now >= until || until.timeIntervalSince(now) > settings.length { finishBreak(now) }
        }
    }

    /// Start now (pill) or Take a Break Now (menu): the break at once, no warning.
    mutating func startNow(_ now: Date) {
        switch phase {
        case .off, .away, .breaking: return
        default: beginBreak(now)
        }
    }

    /// +5 min (§4): the warning comes back in 5 minutes. False during a strict-mode break; the pill keeps it (0022 §4).
    @discardableResult
    mutating func postpone(_ now: Date) -> Bool {
        guard isWarningOrBreaking, settings.allowSkip || isWarning else { return false }
        postponedDue = now.addingTimeInterval(Self.postponement + settings.warning)
        phase = .counting
        return true
    }

    /// Skip (§4): counts as a break taken. False during a strict-mode break; the pill keeps it (0022 §4).
    @discardableResult
    mutating func skip(_ now: Date) -> Bool {
        guard isWarningOrBreaking, settings.allowSkip || isWarning else { return false }
        finishBreak(now)
        return true
    }

    /// Esc held for `escHold` seconds: skips, for a press whose first key-down went to the
    /// app behind. Strict mode ignores Esc; only the countdown or Force Quit ends it (§4).
    mutating func escHeld(_ now: Date) {
        guard settings.allowSkip, case .breaking = phase else { return }
        finishBreak(now)
    }

    /// Pause Eye Breaks ▸ (§7). In memory only.
    mutating func pause(until: Date, now: Date) {
        guard settings.enabled, until > now else { return }
        phase = .paused(until: until)
    }

    /// When the controller must call `tick` next; nil while nothing changes by itself.
    func nextCheck(now: Date) -> Date? {
        let cap = now.addingTimeInterval(Self.tickCap)
        switch phase {
        case .off, .away:
            return nil
        case let .paused(until):
            return min(until, cap)
        case .held:
            return cap
        case .counting:
            if awaitingReturn { return cap }
            return min(max(breakDue.addingTimeInterval(-settings.warning), now), cap)
        case let .warning(until), let .breaking(until):
            return until
        }
    }

    func menuStatus(now: Date) -> MenuStatus {
        switch phase {
        case .off: return .off
        case let .paused(until): return .paused(until: until)
        case .held: return .waiting
        case .away: return .due(in: settings.interval)
        case .counting where awaitingReturn: return .due(in: settings.interval)
        case .counting: return .due(in: max(0, breakDue.timeIntervalSince(now)))
        case let .warning(until): return .due(in: max(0, until.timeIntervalSince(now)))
        case .breaking: return .due(in: 0)
        }
    }

    private var isActive: Bool {
        switch phase {
        case .counting, .held, .warning, .breaking: return true
        case .off, .away, .paused: return false
        }
    }

    private var isWarning: Bool {
        if case .warning = phase { return true }
        return false
    }

    private var isWarningOrBreaking: Bool {
        switch phase {
        case .warning, .breaking: return true
        default: return false
        }
    }

    private func isHeld(_ hold: Hold) -> Bool {
        (settings.holdOnCall && hold.callActive) || hold.bubbleVisible
    }

    private mutating func beginWarning(_ now: Date) {
        if settings.warning > 0 {
            phase = .warning(until: now.addingTimeInterval(settings.warning))
        } else {
            beginBreak(now)
        }
    }

    private mutating func beginBreak(_ now: Date) {
        phase = .breaking(until: now.addingTimeInterval(settings.length))
    }

    private mutating func finishBreak(_ now: Date) {
        breaksTaken += 1
        restartCycle(now)
        phase = .counting
    }

    private mutating func restartCycle(_ start: Date) {
        cycleStart = start
        postponedDue = nil
        awaitingReturn = false
    }
}

extension EyeBreakPlanner.Settings {
    /// From the stored preference (0022 §9). `intervalOverride` is the scratch-only testing hook.
    init(_ stored: EyeBreakSettings, intervalOverride: TimeInterval? = nil) {
        self.init(enabled: stored.enabled,
                  interval: intervalOverride ?? TimeInterval(stored.intervalMinutes) * 60,
                  length: TimeInterval(stored.lengthSeconds),
                  warning: TimeInterval(stored.warnSeconds),
                  allowSkip: stored.allowSkip,
                  holdOnCall: stored.holdOnCall)
    }

    /// `RALLO_EYE_BREAK_SECONDS`, honoured only by a scratch instance (manual checks),
    /// like `RALLO_PREVIEW_UPDATE`. Under 15 s is ignored: the warning needs room.
    static func intervalOverride(environment: [String: String], isScratch: Bool) -> TimeInterval? {
        guard isScratch, let raw = environment["RALLO_EYE_BREAK_SECONDS"], let seconds = TimeInterval(raw),
              seconds >= 15 else { return nil }
        return seconds
    }
}
