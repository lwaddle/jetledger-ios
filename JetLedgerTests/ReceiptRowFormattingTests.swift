//
//  ReceiptRowFormattingTests.swift
//  JetLedgerTests
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
@Suite
struct ReceiptRowFormattingTests {

    /// Returns the container too: `ModelContext` does not retain it, and a
    /// `CachedTripReference` whose container has been deallocated traps on access.
    private func makeCache(
        id: UUID, externalId: String?, name: String?
    ) throws -> (ModelContainer, [CachedTripReference]) {
        let schema = Schema([
            LocalReceipt.self, LocalReceiptPage.self,
            CachedAccount.self, CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ref = CachedTripReference(
            id: id, accountId: UUID(), externalId: externalId, name: name, createdAt: nil
        )
        container.mainContext.insert(ref)
        return (container, [ref])
    }

    // MARK: - Trip label

    @Test
    func prefersTheLocallyStoredTripFields() throws {
        let label = ReceiptRowFormatting.tripLabel(
            externalId: "N4471-0713", name: "Teterboro", tripReferenceId: UUID(), cache: []
        )
        #expect(label == "Trip N4471-0713")
    }

    @Test
    func resolvesAMirroredRowsTripFromTheCache() throws {
        let tripId = UUID()
        let (container, cache) = try makeCache(id: tripId, externalId: "ABC-123", name: "Aspen")
        _ = container

        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: tripId, cache: cache
        )

        #expect(label == "Trip ABC-123")
    }

    @Test
    func fallsBackToTheTripNameWhenThereIsNoExternalId() throws {
        let tripId = UUID()
        let (container, cache) = try makeCache(id: tripId, externalId: nil, name: "Aspen")
        _ = container

        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: tripId, cache: cache
        )

        #expect(label == "Aspen")
    }

    /// A raw UUID is never acceptable row copy.
    @Test
    func omitsTheLabelOnACacheMiss() throws {
        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: UUID(), cache: []
        )
        #expect(label == nil)
    }

    @Test
    func omitsTheLabelWhenThereIsNoTripAtAll() {
        let label = ReceiptRowFormatting.tripLabel(
            externalId: nil, name: nil, tripReferenceId: nil, cache: []
        )
        #expect(label == nil)
    }

    // MARK: - Placeholder glyph

    @Test
    func placeholderCarriesTheSourceForReceiptsThisDeviceNeverCaptured() {
        #expect(ReceiptRowFormatting.placeholderIcon(source: .email, imagesCleanedUp: false) == "envelope.fill")
        #expect(ReceiptRowFormatting.placeholderIcon(source: .upload, imagesCleanedUp: false) == "tray.and.arrow.up.fill")
        #expect(ReceiptRowFormatting.placeholderIcon(source: .ios, imagesCleanedUp: false) == "doc.fill")
        #expect(ReceiptRowFormatting.placeholderIcon(source: nil, imagesCleanedUp: false) == "doc.fill")
    }

    /// Retention's own glyph explains the absence better than the source does.
    @Test
    func cleanedUpImagesKeepTheRetentionGlyph() {
        #expect(ReceiptRowFormatting.placeholderIcon(source: .email, imagesCleanedUp: true)
                == "clock.badge.checkmark")
    }

    // MARK: - Rejection reasons

    @Test
    func mapsTheFourServerRejectionReasons() {
        #expect(ReceiptRowFormatting.rejectionReasonLabel("duplicate") == "Duplicate")
        #expect(ReceiptRowFormatting.rejectionReasonLabel("unreadable") == "Unreadable")
        #expect(ReceiptRowFormatting.rejectionReasonLabel("not_business") == "Not Business")
        #expect(ReceiptRowFormatting.rejectionReasonLabel("other") == "Other")
    }

    @Test
    func humanizesAnUnknownReason() {
        #expect(ReceiptRowFormatting.rejectionReasonLabel("some_new_reason") == "Some New Reason")
    }

    /// syncReceiptStatuses writes a full sentence here; title-casing it would
    /// read as a bug.
    @Test
    func passesThroughTheStatusSyncSentence() {
        let sentence = "Removed during review on the web."
        #expect(ReceiptRowFormatting.rejectionReasonLabel(sentence) == sentence)
    }
}
