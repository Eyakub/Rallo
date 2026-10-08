import Foundation

/// Quick reminder choices offered by the swipe and the context menu.
enum RemindPreset: CaseIterable, Identifiable {
    case inTwentyMinutes, inOneHour, tomorrowMorning

    var id: Self { self }

    var title: String {
        switch self {
        case .inTwentyMinutes: "In 20 Minutes"
        case .inOneHour: "In 1 Hour"
        case .tomorrowMorning: "Tomorrow at 9:00"
        }
    }

    var shortTitle: String {
        switch self {
        case .inTwentyMinutes: "20 min"
        case .inOneHour: "1 hour"
        case .tomorrowMorning: "Tomorrow"
        }
    }

    var symbol: String {
        switch self {
        case .inTwentyMinutes: "bell"
        case .inOneHour: "clock"
        case .tomorrowMorning: "sunrise"
        }
    }

    static func tomorrowMorning(after now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
    }
}

extension ReminderSnapshot {
    var deadline: Date { Date(timeIntervalSince1970: TimeInterval(deadlineMs) / 1000) }
}
