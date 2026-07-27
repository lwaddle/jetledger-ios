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

    /// Without `en_US_POSIX`, a device on a non-Gregorian calendar parses every
    /// server timestamp as nil and the whole list loses its dates.
    @Test
    func parsesIdenticallyRegardlessOfDeviceCalendar() throws {
        let expected = try #require(ServerDateFormatter.date(from: "2026-07-27 14:03:22"))

        let buddhist = DateFormatter()
        buddhist.dateFormat = "yyyy-MM-dd HH:mm:ss"
        buddhist.timeZone = TimeZone(identifier: "UTC")
        buddhist.locale = Locale(identifier: "th_TH_u_ca_buddhist")
        let wrong = buddhist.date(from: "2026-07-27 14:03:22")

        #expect(wrong != expected,
                "sanity: a non-POSIX locale really does parse this differently")
        #expect(ServerDateFormatter.date(from: "2026-07-27 14:03:22") == expected)
    }
}
