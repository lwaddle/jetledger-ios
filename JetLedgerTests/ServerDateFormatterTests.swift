//
//  ServerDateFormatterTests.swift
//  JetLedgerTests
//
//  The server emits SQLite `datetime('now')` output, not ISO-8601. A formatter
//  misconfiguration here silently nils every timestamp in the receipt list.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
struct ServerDateFormatterTests {

    @Test
    func parsesSQLiteDatetimeAsUTC() throws {
        let parsed = try #require(ServerDateFormatter.date(from: "2026-07-27 14:03:22"))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)

        #expect(parts.year == 2026)
        #expect(parts.month == 7)
        #expect(parts.day == 27)
        #expect(parts.hour == 14, "a missing UTC timeZone shifts this by the device offset")
        #expect(parts.minute == 3)
        #expect(parts.second == 22)
    }

    @Test
    func rejectsISO8601Input() {
        #expect(ServerDateFormatter.date(from: "2026-07-27T14:03:22Z") == nil)
    }

    @Test
    func rejectsGarbage() {
        #expect(ServerDateFormatter.date(from: "") == nil)
        #expect(ServerDateFormatter.date(from: "not a date") == nil)
    }

    /// Pins the parsed value to an independently-constructed instant rather than
    /// to another call of the function under test. `en_US_POSIX` is what keeps
    /// this true on a device set to a non-Gregorian calendar; that condition
    /// can't be reproduced here without making the formatter's locale injectable,
    /// so the guarantee is documented at the implementation instead.
    @Test
    func parsesToTheExpectedAbsoluteInstant() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let truth = try #require(utc.date(from: DateComponents(
            year: 2026, month: 7, day: 27, hour: 14, minute: 3, second: 22
        )))

        #expect(ServerDateFormatter.date(from: "2026-07-27 14:03:22") == truth)
    }
}
