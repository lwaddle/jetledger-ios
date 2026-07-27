//
//  ServerDateFormatter.swift
//  JetLedger
//

import Foundation

/// Parses the timestamps the Go API returns. They are SQLite `datetime('now')`
/// output — `"2026-07-27 14:03:22"`, UTC, space-separated, no `T` and no zone
/// suffix — so `ISO8601DateFormatter` fails on every one of them.
///
/// `en_US_POSIX` is not optional: without it a device set to a non-Gregorian
/// calendar parses these to nil and the receipt list loses all of its dates.
nonisolated enum ServerDateFormatter {

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
