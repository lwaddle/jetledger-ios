//
//  ReceiptRowFormatting.swift
//  JetLedger
//

import Foundation

/// Presentation rules shared by the list row and the detail screen. Pure
/// functions so the rules can be tested without standing up a view.
enum ReceiptRowFormatting {

    /// A receipt's trip label.
    ///
    /// Local captures carry the trip's external id and name on the row itself.
    /// A mirrored row has only `trip_reference_id`, so it is resolved against the
    /// cached trip references loaded per account on launch. A miss omits the
    /// label entirely — showing a raw UUID is never acceptable row copy, and the
    /// cache refreshes on the next launch, so misses are rare and self-healing.
    static func tripLabel(
        externalId: String?,
        name: String?,
        tripReferenceId: UUID?,
        cache: [CachedTripReference]
    ) -> String? {
        if let externalId { return "Trip \(externalId)" }
        if let name { return name }

        guard let tripReferenceId,
              let match = cache.first(where: { $0.id == tripReferenceId })
        else { return nil }

        if let externalId = match.externalId { return "Trip \(externalId)" }
        return match.name
    }

    /// The thumbnail placeholder for a receipt with no image on disk.
    ///
    /// For receipts this app never created, the glyph is the only signal that a
    /// receipt the pilot doesn't remember capturing arrived by email or from the
    /// web. Retention's own glyph wins when it applies — "these were cleaned up"
    /// explains the absence better than the source does.
    ///
    /// A PDF outranks the source glyph in turn: the server withholds
    /// `thumbnail_url` for a PDF until its page-1 JPEG has been rendered, which
    /// for an iOS upload that has not been through OCR or opened on the web may
    /// never happen. `doc.fill` there reads as a broken image rather than as a
    /// document with no preview.
    static func placeholderIcon(
        source: ReceiptSource?,
        imagesCleanedUp: Bool,
        isPDF: Bool = false
    ) -> String {
        if imagesCleanedUp { return "clock.badge.checkmark" }
        if isPDF { return "doc.richtext" }
        switch source {
        case .email: return "envelope.fill"
        case .upload: return "tray.and.arrow.up.fill"
        case .ios, nil: return "doc.fill"
        }
    }

    /// Server rejection reasons are `duplicate`, `unreadable`, `not_business`,
    /// `other`. Anything else — including the sentence `syncReceiptStatuses`
    /// writes for a receipt removed during web review — is humanized or passed
    /// through unchanged.
    static func rejectionReasonLabel(_ reason: String) -> String {
        switch reason {
        case "duplicate": return "Duplicate"
        case "unreadable": return "Unreadable"
        case "not_business": return "Not Business"
        case "other": return "Other"
        default:
            guard reason.contains("_") else { return reason }
            return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
