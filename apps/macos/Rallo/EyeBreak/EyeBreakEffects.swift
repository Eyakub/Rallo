import CoreGraphics
import Foundation

/// What `EyeBreakController` does when the planner's phase changes (0022 §3-§5).
enum EyeBreakEffect: Equatable {
    case showPill(until: Date)
    case hidePill
    /// The pet's `nudge` pose for the warning (§3), and back.
    case nudgePet(Bool)
    /// Records the frontmost app, shows a window per screen, activates Rallo.
    case showOverlay(until: Date)
    case closeOverlay
    /// Re-activates the app recorded by `showOverlay`, whether or not Rallo ever became active.
    case restoreFocus
    case toast(nextIn: TimeInterval)
    /// 0021 §8: a reminder round waiting for the break runs now.
    case resumeAlerts
}

enum EyeBreakEffects {
    static func between(_ old: EyeBreakPlanner, _ new: EyeBreakPlanner) -> [EyeBreakEffect] {
        var effects: [EyeBreakEffect] = []
        let oldWarning = old.phase.warningUntil, newWarning = new.phase.warningUntil
        let oldBreak = old.phase.breakingUntil, newBreak = new.phase.breakingUntil
        if oldWarning != nil, newWarning == nil { effects += [.hidePill, .nudgePet(false)] }
        if let until = newWarning, until != oldWarning {
            if oldWarning == nil { effects.append(.nudgePet(true)) }
            effects.append(.showPill(until: until))
        }
        if oldBreak != nil, newBreak == nil {
            effects += [.closeOverlay, .restoreFocus]
            // Completed, skipped or held Esc; not +5 min, a lock, or turning off (§5).
            if new.breaksTaken > old.breaksTaken { effects.append(.toast(nextIn: new.settings.interval)) }
            effects.append(.resumeAlerts)
        }
        if let until = newBreak, until != oldBreak { effects.append(.showOverlay(until: until)) }
        return effects
    }
}

private extension EyeBreakPlanner.Phase {
    var warningUntil: Date? {
        if case let .warning(until) = self { return until }
        return nil
    }

    var breakingUntil: Date? {
        if case let .breaking(until) = self { return until }
        return nil
    }
}

/// Eye-break copy (0022 §3-§7).
enum EyeBreakText {
    /// "12:34", "0:08"; rounded up so it never shows 0:00 early.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func pill(_ seconds: TimeInterval) -> String {
        "Eye break in \(max(0, Int(seconds.rounded(.up)))) s"
    }

    static func statusLine(_ status: EyeBreakPlanner.MenuStatus, locale: Locale = .current,
                           timeZone: TimeZone = .current) -> String? {
        switch status {
        case .off:
            return nil
        case let .due(seconds):
            return "Eye break in \(clock(seconds))"
        case let .paused(until):
            let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
            return "Eye breaks paused until \(time)"
        case .waiting:
            return "Eye break when you’re free"
        }
    }

    static func toast(nextIn seconds: TimeInterval) -> String {
        seconds >= 60
            ? "Eyes rested · next in \(Int((seconds / 60).rounded())) min"
            : "Eyes rested · next in \(Int(seconds)) s"
    }

    static func announcement(length: TimeInterval) -> String { "Eye break, \(Int(length)) seconds" }
}

/// Pause Eye Breaks ▸ (§7). The raw value is the menu item's tag.
enum EyeBreakPause: Int, CaseIterable {
    case thirtyMinutes, oneHour, untilTomorrow

    var title: String {
        switch self {
        case .thirtyMinutes: "For 30 Minutes"
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        }
    }

    /// Until Tomorrow is the next local midnight.
    func until(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtyMinutes: return now.addingTimeInterval(30 * 60)
        case .oneHour: return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                ?? now.addingTimeInterval(24 * 60 * 60)
        }
    }
}

enum EyeBreakLayout {
    /// The screen under the mouse gets the countdown (§4); off every screen, the first.
    static func mainIndex(screens: [CGRect], mouse: CGPoint) -> Int {
        // Inclusive: AppKit reports a pointer at a display's top edge as y == maxY (the pill uses NSMouseInRect).
        screens.firstIndex { mouse.x >= $0.minX && mouse.x <= $0.maxX && mouse.y >= $0.minY && mouse.y <= $0.maxY } ?? 0
    }
}
