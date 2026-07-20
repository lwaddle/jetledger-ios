//
//  ReceiptDateFormatter.swift
//  JetLedger
//

import Foundation

/// Formats a receipt's capture date as a row title. A receipt has no merchant
/// or amount in v1, so the capture date is the row's primary identity.
nonisolated enum ReceiptDateFormatter {

    static func rowTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)

        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            let monthDay = date.formatted(.dateTime.month(.abbreviated).day())
            return "\(monthDay), \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
