import Foundation

enum ReminderLabel {
    /// "today at 14:20", "tomorrow at 9:00", or "Fri 3 Oct at 9:00".
    static func text(for date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(day) at \(time)"
    }
}
