//
//  ReceiptDateFormatterTests.swift
//  JetLedgerTests
//

import Foundation
import Testing
@testable import JetLedger

struct ReceiptDateFormatterTests {

    // Fixed reference point: Mon Jul 20, 2026, 14:00 local time.
    private let calendar = Calendar.current
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 14))!
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9, minute: Int = 5) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func sameDayIsTodayWithTime() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2026, 7, 20), now: now, calendar: calendar)
        #expect(title.hasPrefix("Today, "))
        #expect(title.contains("9"))  // time component present
    }

    @Test func previousDayIsYesterdayWithTime() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2026, 7, 19), now: now, calendar: calendar)
        #expect(title.hasPrefix("Yesterday, "))
    }

    @Test func sameYearShowsMonthDayAndTimeButNoYear() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2026, 7, 12), now: now, calendar: calendar)
        #expect(title.contains("12"))
        #expect(!title.contains("2026"))
        #expect(!title.hasPrefix("Today"))
        #expect(!title.hasPrefix("Yesterday"))
    }

    @Test func priorYearShowsYearWithoutTime() {
        let title = ReceiptDateFormatter.rowTitle(for: date(2025, 12, 3), now: now, calendar: calendar)
        #expect(title.contains("2025"))
        #expect(!title.contains(":"))  // no time on prior-year dates
    }

    /// Year boundary: Dec 31 vs Jan 1 are different years but only a day apart —
    /// Dec 31 captured yesterday must still say "Yesterday", not "Dec 31, 2025".
    @Test func yesterdayWinsAcrossYearBoundary() {
        let jan1 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!
        let dec31 = date(2025, 12, 31)
        let title = ReceiptDateFormatter.rowTitle(for: dec31, now: jan1, calendar: calendar)
        #expect(title.hasPrefix("Yesterday, "))
    }
}
