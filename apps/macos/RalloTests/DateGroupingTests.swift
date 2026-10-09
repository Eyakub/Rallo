import XCTest

final class DateGroupingTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let british = Locale(identifier: "en_GB")

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTheDayBoundaries() {
        let utc = calendar()
        let now = date(utc, 2026, 10, 8, 10, 42)
        func group(_ date: Date) -> DateGroup { DateGrouping.group(for: date, now: now, calendar: utc) }
        XCTAssertEqual(group(date(utc, 2026, 10, 8, 0, 0)), .today)
        XCTAssertEqual(group(date(utc, 2026, 10, 7, 23, 59)), .yesterday)
        XCTAssertEqual(group(date(utc, 2026, 10, 7, 0, 0)), .yesterday)
        XCTAssertEqual(group(date(utc, 2026, 10, 6, 23, 59)), .previous7Days)
        XCTAssertEqual(group(date(utc, 2026, 10, 1, 0, 0)), .previous7Days)
        XCTAssertEqual(group(date(utc, 2026, 9, 30, 23, 59)), .previous30Days)
        XCTAssertEqual(group(date(utc, 2026, 9, 8, 0, 0)), .previous30Days)
        XCTAssertEqual(group(date(utc, 2026, 9, 7, 23, 59)), .month(year: 2026, month: 9))
        XCTAssertEqual(group(date(utc, 2026, 10, 9, 8, 0)), .today, "a clock a little ahead is still today")
    }

    func testMonthTitlesDropTheYearOnlyInTheCurrentYear() {
        let utc = calendar()
        let now = date(utc, 2026, 3, 15)
        XCTAssertEqual(DateGrouping.title(.month(year: 2026, month: 1), now: now, calendar: utc, locale: english), "January")
        XCTAssertEqual(DateGrouping.title(.month(year: 2025, month: 12), now: now, calendar: utc, locale: english), "December 2025")
        XCTAssertEqual(DateGrouping.title(.today, now: now, calendar: utc, locale: english), "Today")
        XCTAssertEqual(DateGrouping.title(.yesterday, now: now, calendar: utc, locale: english), "Yesterday")
        XCTAssertEqual(DateGrouping.title(.previous7Days, now: now, calendar: utc, locale: english), "Previous 7 Days")
        XCTAssertEqual(DateGrouping.title(.previous30Days, now: now, calendar: utc, locale: english), "Previous 30 Days")
    }

    func testTheYearBoundary() {
        let utc = calendar()
        let january = date(utc, 2026, 1, 5)
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2025, 12, 20), now: january, calendar: utc), .previous30Days)
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2025, 11, 30), now: january, calendar: utc), .month(year: 2025, month: 11))
        let march = date(utc, 2026, 3, 15)
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2025, 12, 31), now: march, calendar: utc), .month(year: 2025, month: 12))
        XCTAssertEqual(DateGrouping.group(for: date(utc, 2026, 1, 10), now: march, calendar: utc), .month(year: 2026, month: 1))
    }

    func testTheSameInstantFallsOnDifferentDaysInDifferentTimeZones() {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-10-08T23:30:00Z")!
        let note = formatter.date(from: "2026-10-08T10:30:00Z")!
        // Kiritimati (UTC+14) is already on the 9th and its midnight was 10:00Z; Pago Pago (UTC-11) midnight is 11:00Z.
        XCTAssertEqual(DateGrouping.group(for: note, now: now, calendar: calendar("Pacific/Kiritimati")), .today)
        XCTAssertEqual(DateGrouping.group(for: note, now: now, calendar: calendar("Pacific/Pago_Pago")), .yesterday)
    }

    func testYesterdayAcrossADaylightSavingChange() {
        let newYork = calendar("America/New_York")  // clocks went back on 1 November 2026: that day has 25 hours
        let now = date(newYork, 2026, 11, 2, 9, 0)
        XCTAssertEqual(DateGrouping.group(for: date(newYork, 2026, 11, 1, 0, 0), now: now, calendar: newYork), .yesterday)
        XCTAssertEqual(DateGrouping.group(for: date(newYork, 2026, 10, 31, 23, 59), now: now, calendar: newYork), .previous7Days)
    }

    func testSectionsKeepFirstAppearanceOrderAndMergeTheSameGroup() {
        let utc = calendar()
        let now = date(utc, 2026, 10, 8, 10, 42)
        func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        let stamps = [
            ms(date(utc, 2026, 10, 8, 9)), ms(date(utc, 2026, 10, 7, 9)), ms(date(utc, 2026, 10, 8, 8)),
            ms(date(utc, 2026, 8, 20)), ms(date(utc, 2025, 8, 20)),
        ]
        let sections = DateGrouping.sections(stamps, timestampMs: { $0 }, now: now, calendar: utc, locale: english)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "August", "August 2025"])
        XCTAssertEqual(sections.map(\.elements.count), [2, 1, 1, 1])
        XCTAssertEqual(Set(sections.map(\.id)).count, 4, "ids are unique, so ForEach never sees a duplicate")
    }

    func testRowTimeIsTheTimeTodayTheWeekdayThisWeekElseTheDate() {
        let utc = calendar()
        let now = date(utc, 2026, 10, 8, 10, 42)
        func label(_ date: Date) -> String { RowTimeLabel.text(for: date, now: now, calendar: utc, locale: british) }
        XCTAssertEqual(label(date(utc, 2026, 10, 8, 10, 42)), "10:42")
        XCTAssertEqual(label(date(utc, 2026, 10, 6, 9, 0)), "Tuesday")
        XCTAssertEqual(label(date(utc, 2026, 10, 2, 9, 0)), "Friday")
        XCTAssertEqual(label(date(utc, 2026, 10, 1, 9, 0)), "01/10/2026")
    }
}
