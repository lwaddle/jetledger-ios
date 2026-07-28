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

    // MARK: - DTO builders

    private func summary(
        id: UUID,
        status: String = "pending",
        source: String = "email",
        note: String? = nil,
        tripReferenceId: UUID? = nil,
        createdAt: String = "2026-07-20 12:00:00",
        updatedAt: String = "2026-07-20 12:00:00",
        imageCount: Int = 1
    ) throws -> ReceiptSummaryDTO {
        var fields: [String] = [
            "\"id\":\"\(id.uuidString.lowercased())\"",
            "\"status\":\"\(status)\"",
            "\"source\":\"\(source)\"",
            "\"ocr_status\":\"pending\"",
            "\"image_count\":\(imageCount)",
            "\"created_at\":\"\(createdAt)\"",
            "\"updated_at\":\"\(updatedAt)\""
        ]
        if let note { fields.append("\"note\":\"\(note)\"") }
        if let tripReferenceId {
            fields.append("\"trip_reference_id\":\"\(tripReferenceId.uuidString.lowercased())\"")
        }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(ReceiptSummaryDTO.self, from: Data(json.utf8))
    }

    // MARK: - Upsert

    @Test
    func upsertCreatesAMirroredRowMarkedRemoteAndUploaded() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        mirror.upsert([try summary(id: serverId, status: "rejected", source: "email")], accountId: accountId)

        let rows = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.serverReceiptId == serverId)
        #expect(row.accountId == accountId)
        #expect(row.isRemote == true)
        #expect(row.source == .email)
        #expect(row.serverStatus == .rejected)
        #expect(row.syncStatus == .uploaded,
                "a mirrored row must never be picked up by the upload queue")
        #expect(row.serverCreatedAt == ServerDateFormatter.date(from: "2026-07-20 12:00:00"))
        #expect(row.capturedAt == row.serverCreatedAt,
                "a mirrored row has no capture date of its own")
        #expect(row.terminalStatusAt != nil, "a rejected row must be terminal so retention applies")
    }

    /// This is what collapses a device's own upload into one row instead of two.
    @Test
    func upsertMergesOntoAnExistingLocalRowByServerReceiptId() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let page = LocalReceiptPage(sortOrder: 0, localImagePath: "receipts/x/page-001.jpg")
        let local = LocalReceipt(
            id: UUID(), accountId: accountId, capturedAt: captured, syncStatus: .uploaded, pages: [page]
        )
        local.serverReceiptId = serverId
        context.insert(local)
        page.receipt = local
        context.insert(page)
        try context.save()

        mirror.upsert([try summary(id: serverId, status: "processed", source: "ios")], accountId: accountId)

        let rows = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(rows.count == 1, "the server row must merge, not duplicate")
        let row = try #require(rows.first)
        #expect(row.serverStatus == .processed)
        #expect(row.isRemote == false, "a local capture stays local-origin after it uploads")
        #expect(row.capturedAt == captured, "the server must not overwrite the local capture date")
        #expect(row.pages.count == 1, "local pages must survive an upsert")
    }

    /// The whole point of persisting the flag: a refetch must not resurrect a
    /// receipt the user dismissed.
    @Test
    func upsertPreservesADismissedFlag() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        mirror.upsert([try summary(id: serverId, status: "rejected")], accountId: accountId)
        let row = try #require(try context.fetch(FetchDescriptor<LocalReceipt>()).first)
        row.dismissedAt = Date()
        try context.save()

        mirror.upsert([try summary(id: serverId, status: "rejected")], accountId: accountId)

        let after = try #require(try context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(after.dismissedAt != nil)
    }

    @Test
    func upsertAppliesServerOwnedMetadata() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let tripId = UUID()

        mirror.upsert(
            [try summary(id: UUID(), note: "Fuel KTEB", tripReferenceId: tripId, imageCount: 3)],
            accountId: accountId
        )

        let row = try #require(try context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(row.note == "Fuel KTEB")
        #expect(row.tripReferenceId == tripId)
        #expect(row.imageCount == 3)
    }

    @Test
    func upsertIsIdempotent() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let dto = try summary(id: UUID())

        mirror.upsert([dto], accountId: accountId)
        mirror.upsert([dto], accountId: accountId)
        mirror.upsert([dto], accountId: accountId)

        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }

    @Test
    func upsertScopesRowsToTheirAccount() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()
        let sharedId = UUID()

        mirror.upsert([try summary(id: sharedId)], accountId: accountA)
        mirror.upsert([try summary(id: sharedId)], accountId: accountB)

        let rows = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(rows.count == 2, "the same server id under a different tenant is a different row")
        #expect(Set(rows.map(\.accountId)) == Set([accountA, accountB]))
    }

    // MARK: - Detail upsert

    private func detailDTO(serverId: UUID, imagesJSON: String) throws -> ReceiptDetailDTO {
        let json = """
        {"id":"\(serverId.uuidString.lowercased())","status":"pending","source":"email",
         "ocr_status":"completed","image_count":2,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00",
         "images":[\(imagesJSON)]}
        """
        return try JSONDecoder().decode(ReceiptDetailDTO.self, from: Data(json.utf8))
    }

    @Test
    func upsertDetailCreatesPagesAwaitingDownload() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let dto = try detailDTO(serverId: UUID(), imagesJSON: """
        {"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
         "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0},
        {"id":"b21d0000-0000-4000-8000-000000000004","file_path":"tenants/a/two.pdf",
         "file_name":"two.pdf","mime_type":"application/pdf","sort_order":1}
        """)

        let row = try #require(mirror.upsertDetail(dto, accountId: accountId))

        #expect(row.detailFetchedAt != nil)
        let pages = row.pages.sorted { $0.sortOrder < $1.sortOrder }
        #expect(pages.count == 2)
        #expect(pages[0].serverFilePath == "tenants/a/one.jpg")
        #expect(pages[0].contentType == .jpeg)
        #expect(pages[0].imageDownloaded == false, "mirrored pages have no bytes yet")
        #expect(pages[1].contentType == .pdf)
        #expect(pages[1].sortOrder == 1)
    }

    @Test
    func upsertDetailIsIdempotentOnImageIds() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let dto = try detailDTO(serverId: UUID(), imagesJSON: """
        {"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
         "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0}
        """)

        _ = mirror.upsertDetail(dto, accountId: accountId)
        let row = try #require(mirror.upsertDetail(dto, accountId: accountId))

        #expect(row.pages.count == 1, "re-fetching detail must not duplicate pages")
    }

    /// A local capture's pages point at real files on disk. A detail response
    /// must annotate them, never replace them.
    @Test
    func upsertDetailDoesNotDisturbALocalCapturesPages() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let serverId = UUID()

        let page = LocalReceiptPage(sortOrder: 0, localImagePath: "receipts/x/page-001.jpg")
        let local = LocalReceipt(id: UUID(), accountId: accountId, syncStatus: .uploaded, pages: [page])
        local.serverReceiptId = serverId
        context.insert(local)
        page.receipt = local
        context.insert(page)
        try context.save()

        let dto = try detailDTO(serverId: serverId, imagesJSON: """
        {"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
         "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0}
        """)

        let row = try #require(mirror.upsertDetail(dto, accountId: accountId))

        #expect(row.pages.count == 1)
        let updated = try #require(row.pages.first)
        #expect(updated.localImagePath == "receipts/x/page-001.jpg",
                "the local file path must survive")
        #expect(updated.imageDownloaded == true, "the bytes are still on disk")
        #expect(updated.serverFilePath == "tenants/a/one.jpg",
                "but the page now knows its server object")
    }

    // MARK: - Prune

    @Test
    func pruneRemovesAMirroredRowMissingFromItsOwnDateRange() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let keptId = UUID()
        let goneId = UUID()

        mirror.upsert([
            try summary(id: keptId, createdAt: "2026-07-25 12:00:00"),
            try summary(id: goneId, createdAt: "2026-07-20 12:00:00")
        ], accountId: accountId)
        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 2)

        // A later page covering the same window no longer contains goneId.
        let deleted = mirror.prune([
            try summary(id: keptId, createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-18 12:00:00")
        ], accountId: accountId)

        let remaining = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(!remaining.contains { $0.serverReceiptId == goneId },
                "a row inside the fetched window but absent from it was deleted on the web")
        #expect(remaining.contains { $0.serverReceiptId == keptId })
        #expect(deleted.count == 1)
    }

    @Test
    func pruneLeavesRowsOutsideTheFetchedRangeAlone() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let olderId = UUID()

        mirror.upsert([try summary(id: olderId, createdAt: "2026-06-01 12:00:00")], accountId: accountId)

        _ = mirror.prune([
            try summary(id: UUID(), createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-20 12:00:00")
        ], accountId: accountId)

        let remaining = try context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(remaining.contains { $0.serverReceiptId == olderId },
                "a page proves nothing about receipts older than its oldest entry")
    }

    /// A receipt that got its serverReceiptId after this request went out is
    /// legitimately absent from the response. Deleting it would destroy the only
    /// copy of the user's images.
    @Test
    func pruneNeverTouchesALocalOriginRow() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()

        let local = LocalReceipt(
            id: UUID(),
            accountId: accountId,
            capturedAt: try #require(ServerDateFormatter.date(from: "2026-07-22 12:00:00")),
            syncStatus: .uploaded
        )
        local.serverReceiptId = UUID()
        local.serverCreatedAt = ServerDateFormatter.date(from: "2026-07-22 12:00:00")
        local.isRemote = false
        context.insert(local)
        try context.save()

        _ = mirror.prune([
            try summary(id: UUID(), createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-20 12:00:00")
        ], accountId: accountId)

        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "a local capture is only ever removed by the user or status sync")
    }

    @Test
    func pruneIgnoresOtherAccounts() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountA = UUID()
        let accountB = UUID()

        mirror.upsert([try summary(id: UUID(), createdAt: "2026-07-22 12:00:00")], accountId: accountB)

        _ = mirror.prune([
            try summary(id: UUID(), createdAt: "2026-07-25 12:00:00"),
            try summary(id: UUID(), createdAt: "2026-07-20 12:00:00")
        ], accountId: accountA)

        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }

    @Test
    func pruneOnAnEmptyResponseDeletesNothing() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()

        mirror.upsert([try summary(id: UUID())], accountId: accountId)

        let deleted = mirror.prune([], accountId: accountId)

        #expect(deleted.isEmpty, "an empty page describes no window and proves nothing")
        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }

    @Test
    func pruneKeepsRowsPresentInTheResponse() throws {
        let store = try Self.makeStore()
        let context = store.context
        let mirror = ReceiptMirror(modelContext: context)
        let accountId = UUID()
        let id = UUID()
        let page = [try summary(id: id, createdAt: "2026-07-22 12:00:00")]

        mirror.upsert(page, accountId: accountId)
        let deleted = mirror.prune(page, accountId: accountId)

        #expect(deleted.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
    }
}
