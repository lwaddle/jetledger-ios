//
//  ReceiptMirrorTests.swift
//  JetLedgerTests
//
//  Covers the schema fields the server mirror depends on and the reconciliation
//  rules that decide which local rows a server response may create, update, or
//  destroy.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
@Suite
struct ReceiptMirrorTests {

    // MARK: - Harness

    /// Holds the container alongside the context. `ModelContext` does not keep
    /// its container alive, so returning a bare `container.mainContext` leaves
    /// the container to be deallocated out from under it — SwiftData then traps
    /// on the next use. `SyncServiceRetryTests.Harness` carries an otherwise
    /// unread `container` field for exactly this reason.
    struct Store {
        let container: ModelContainer
        let context: ModelContext
    }

    static func makeStore() throws -> Store {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return Store(container: container, context: container.mainContext)
    }

    // MARK: - Schema defaults

    /// These defaults are what make the SwiftData migration lightweight: every
    /// pre-existing row is a local capture with bytes on disk, and the defaults
    /// must already say so without any migration code.
    @Test
    func existingRowDefaultsDescribeALocalCaptureWithFilesOnDisk() throws {
        // `store` must stay in scope: it owns the container the context needs.
        let store = try Self.makeStore()
        let context = store.context
        let page = LocalReceiptPage(sortOrder: 0, localImagePath: "receipts/x/page-001.jpg")
        let receipt = LocalReceipt(accountId: UUID(), pages: [page])
        context.insert(receipt)

        #expect(receipt.isRemote == false, "a row with no server origin is a local capture")
        #expect(page.imageDownloaded == true, "an existing capture already has its bytes")
        #expect(receipt.dismissedAt == nil)
        #expect(receipt.detailFetchedAt == nil)
        #expect(receipt.imageCount == 0)
        #expect(page.serverFilePath == nil)
        #expect(page.imageDownloadedAt == nil)
    }

    @Test
    func typedAccessorsRoundTripThroughRawStrings() throws {
        // `store` must stay in scope: it owns the container the context needs.
        let store = try Self.makeStore()
        let context = store.context
        let receipt = LocalReceipt(accountId: UUID())
        context.insert(receipt)

        receipt.source = .email
        receipt.ocrStatus = .completed

        #expect(receipt.sourceRaw == "email")
        #expect(receipt.ocrStatusRaw == "completed")
        #expect(receipt.source == .email)
        #expect(receipt.ocrStatus == .completed)
    }

    @Test
    func unknownRawValuesDecodeToNilRatherThanCrashing() throws {
        // `store` must stay in scope: it owns the container the context needs.
        let store = try Self.makeStore()
        let context = store.context
        let receipt = LocalReceipt(accountId: UUID())
        context.insert(receipt)

        receipt.sourceRaw = "carrier_pigeon"
        receipt.ocrStatusRaw = "thinking"

        #expect(receipt.source == nil, "a future server value must not trap the app")
        #expect(receipt.ocrStatus == nil)
    }

    @Test
    func pageSizeIsWithinTheServersClampRange() {
        #expect(AppConstants.ReceiptList.pageSize >= 1)
        #expect(AppConstants.ReceiptList.pageSize <= 100)
    }
}
