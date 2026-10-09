import Foundation

/// The date sections of the notes window's list (0019 §11).
enum DateGroup: Hashable {
    case today, yesterday, previous7Days, previous30Days
    case month(year: Int, month: Int)
}

struct DateSection<Element>: Identifiable {
    let group: DateGroup
    let title: String
    let elements: [Element]

    var id: DateGroup { group }
}

enum DateGrouping {
    /// Whole days in the calendar's time zone: Today is since midnight,
    /// Yesterday the day before, Previous 7 Days reaches back 7 days from
    /// today's midnight, Previous 30 Days 30; older notes sit in their month.
    static func group(for date: Date, now: Date, calendar: Calendar) -> DateGroup {
        let today = calendar.startOfDay(for: now)
        func midnight(daysBack: Int) -> Date { calendar.date(byAdding: .day, value: -daysBack, to: today)! }
        if date >= today { return .today }
        if date >= midnight(daysBack: 1) { return .yesterday }
        if date >= midnight(daysBack: 7) { return .previous7Days }
        if date >= midnight(daysBack: 30) { return .previous30Days }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year!, month: parts.month!)
    }

    /// "Today" … "September", or "August 2025" outside the current year.
    static func title(_ group: DateGroup, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        switch group {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case let .month(year, month):
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            let thisYear = calendar.component(.year, from: now) == year
            formatter.setLocalizedDateFormatFromTemplate(thisYear ? "LLLL" : "LLLL y")
            let firstNoon = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))!
            return formatter.string(from: firstNoon)
        }
    }

    /// Sections in order of first appearance (`elements` should already be
    /// newest first); the same group never appears twice.
    static func sections<Element>(
        _ elements: [Element], timestampMs: (Element) -> Int64, now: Date, calendar: Calendar, locale: Locale = .current
    ) -> [DateSection<Element>] {
        var order: [DateGroup] = []
        var buckets: [DateGroup: [Element]] = [:]
        for element in elements {
            let date = Date(timeIntervalSince1970: TimeInterval(timestampMs(element)) / 1000)
            let group = group(for: date, now: now, calendar: calendar)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(element)
        }
        return order.map {
            DateSection(group: $0, title: title($0, now: now, calendar: calendar, locale: locale), elements: buckets[$0]!)
        }
    }
}

/// The time on a list row: today `10:42`, within the last week the weekday,
/// else the date.
enum RowTimeLabel {
    static func text(for date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if date >= today {
            formatter.setLocalizedDateFormatFromTemplate("jm")
        } else if date >= weekStart {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yMd")
        }
        return formatter.string(from: date)
    }
}
