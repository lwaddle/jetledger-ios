//
//  ReceiptRetentionTests.swift
//  JetLedgerTests
//
//  Retention reclaims disk, not metadata. With the server as the source of truth
//  for the list, deleting a record destroys local-only state (a dismissed flag)
//  that no refetch can restore.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct ReceiptRetentionTests {

    init() {
        MockURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: AppConstants.Cleanup.imageRetentionKey)
    }

    /// Holds the container: `ModelContext` does not retain it, and a deallocated
    /// container traps inside SwiftData.
    private struct Harness {
        let sync: SyncService
        let context: ModelContext
        let container: ModelContainer
    }

    private func makeHarness() throws -> Harness {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let monitor = NetworkMonitor()
        monitor.setConnectedForTesting(false)
        let apiClient = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        let sync = SyncService(
            receiptAPI: ReceiptAPIService(apiClient: apiClient),
            r2Upload: R2UploadService(session: MockURLProtocol.makeSession()),
            networkMonitor: monitor,
            modelContext: container.mainContext
        )
        return Harness(sync: sync, context: container.mainContext, container: container)
    }

    /// Writes a receipt with one real page file on disk.
    @discardableResult
    private func makeReceipt(
        in context: ModelContext,
        terminalDaysAgo: Int?,
        imageDownloadedDaysAgo: Int? = nil,
        isRemote: Bool = false
    ) throws -> LocalReceipt {
        let receiptId = UUID()
        let relativePath = "receipts/\(receiptId.uuidString)/page-001.jpg"
        let dir = ImageUtils.documentsDirectory()
            .appendingPathComponent("receipts/\(receiptId.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 64).write(to: dir.appendingPathComponent("page-001.jpg"))

        let page = LocalReceiptPage(sortOrder: 0, localImagePath: relativePath)
        if let days = imageDownloadedDaysAgo {
            page.imageDownloadedAt = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        let receipt = LocalReceipt(id: receiptId, accountId: UUID(), syncStatus: .uploaded)
        receipt.serverReceiptId = UUID()
        receipt.serverStatus = .processed
        receipt.isRemote = isRemote
        if let days = terminalDaysAgo {
            receipt.terminalStatusAt = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        context.insert(receipt)
        context.insert(page)
        page.receipt = receipt
        try context.save()
        return receipt
    }

    /// Fixtures write raw bytes, not encodable images, so `loadReceiptImage`
    /// returns nil for them whether or not the file is there — asserting on it
    /// would pass vacuously in both directions. Retention deletes *files*, so
    /// that is what these tests check.
    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: ImageUtils.documentsDirectory().appendingPathComponent(relativePath).path
        )
    }

    // MARK: - Phase 1

    @Test
    func phaseOneDeletesImagesAndMarksThemRedownloadable() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 10)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(receipt.imagesCleanedUp == true)
        #expect(!fileExists(path))
        #expect(receipt.pages.first?.imageDownloaded == false,
                "a cleaned page must be re-downloadable, not a permanent dead end")
    }

    @Test
    func phaseOneLeavesRecentTerminalReceiptsAlone() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 1)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(receipt.imagesCleanedUp == false)
        #expect(fileExists(path))
    }

    // MARK: - Phase 2 removal

    /// The record is a mirror of a row the server owns. Deleting it only causes
    /// a refetch — and loses the dismissed flag on the way.
    @Test
    func aLongTerminalReceiptKeepsItsRecord() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 60)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }

        let deleted = h.sync.performCleanup()

        #expect(deleted.isEmpty)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "retention reclaims disk, not the server's own metadata")
        #expect(receipt.imagesCleanedUp == true, "its images are still reclaimed")
    }

    /// The exact regression that forced phase 2's removal.
    @Test
    func dismissedFlagSurvivesCleanup() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: 60)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        receipt.dismissedAt = Date()
        try h.context.save()

        h.sync.performCleanup()

        let remaining = try #require(try h.context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(remaining.dismissedAt != nil,
                "deleting the record would resurrect a receipt the user dismissed")
    }

    // MARK: - Downloaded-image reclaim

    /// A pending email receipt never becomes terminal, so a terminal-status clock
    /// would never reclaim its downloaded image.
    @Test
    func downloadedImagesPastTheWindowAreReclaimed() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, terminalDaysAgo: nil, imageDownloadedDaysAgo: 30, isRemote: true
        )
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(!fileExists(path))
        #expect(receipt.pages.first?.imageDownloaded == false)
        #expect(receipt.pages.first?.imageDownloadedAt == nil)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "only the bytes go; the row stays")
    }

    @Test
    func recentlyDownloadedImagesAreKept() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, terminalDaysAgo: nil, imageDownloadedDaysAgo: 1, isRemote: true
        )
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(fileExists(path))
    }

    /// An original capture has no download stamp — its only copy is on this
    /// device and the download clock must never touch it.
    @Test
    func anOriginalCaptureIsNeverReclaimedByTheDownloadClock() throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, terminalDaysAgo: nil)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        let path = try #require(receipt.pages.first?.localImagePath)

        h.sync.performCleanup()

        #expect(receipt.pages.first?.imageDownloadedAt == nil)
        #expect(fileExists(path),
                "a local capture with no download stamp is not download-cache")
    }
}

} // MockURLProtocolSuites
