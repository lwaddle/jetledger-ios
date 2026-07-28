//
//  ReceiptImageDownloaderTests.swift
//  JetLedgerTests
//
//  Covers on-demand image fetch for receipts this device never captured, and for
//  local captures whose images retention has already reclaimed.
//

import Testing
import Foundation
import SwiftData
import UIKit
@testable import JetLedger

extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct ReceiptImageDownloaderTests {

    init() {
        MockURLProtocol.reset()
    }

    // MARK: - Harness

    /// Holds the container: `ModelContext` does not retain it, and a deallocated
    /// container traps inside SwiftData.
    private struct Harness {
        let downloader: ReceiptImageDownloader
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
        let apiClient = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        let downloader = ReceiptImageDownloader(
            receiptAPI: ReceiptAPIService(apiClient: apiClient),
            modelContext: container.mainContext,
            session: MockURLProtocol.makeSession()
        )
        return Harness(
            downloader: downloader, context: container.mainContext, container: container
        )
    }

    /// A small real JPEG, so the thumbnail step has something decodable.
    private static func jpegBytes() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    private static func pdfBytes() throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @discardableResult
    private func makeRemoteReceipt(
        in context: ModelContext,
        serverFilePath: String? = "tenants/a/one.jpg",
        contentType: PageContentType = .jpeg
    ) throws -> LocalReceipt {
        let receiptId = UUID()
        let page = LocalReceiptPage(
            sortOrder: 0,
            localImagePath: "receipts/\(receiptId.uuidString)/page-001.\(contentType.fileExtension)",
            contentType: contentType
        )
        page.serverFilePath = serverFilePath
        page.serverImageId = UUID()
        page.imageDownloaded = false
        let receipt = LocalReceipt(id: receiptId, accountId: UUID(), syncStatus: .uploaded)
        receipt.serverReceiptId = UUID()
        receipt.isRemote = true
        context.insert(receipt)
        context.insert(page)
        page.receipt = receipt
        try context.save()
        return receipt
    }

    /// Routes download-url, then the object GET.
    private func installDownloadHandler(bytes: Data) {
        MockURLProtocol.handler = { request in
            let url = request.url!
            if url.path == "/api/receipts/download-url" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"download_url":"https://example.test/r2/object","expires_in":900}"#
                        .data(using: .utf8)!
                )
            }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                bytes
            )
        }
    }

    /// Counts requests so "did not hit the network" is a real assertion.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func installCountingHandler(_ counter: Counter) {
        MockURLProtocol.handler = { request in
            counter.bump()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
    }

    // MARK: - Tests

    @Test
    func downloadsMissingImageAndWritesItToDisk() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        installDownloadHandler(bytes: try Self.jpegBytes())

        try await h.downloader.downloadMissingImages(for: receipt)

        let page = try #require(receipt.pages.first)
        #expect(page.imageDownloaded == true)
        #expect(page.imageDownloadedAt != nil)
        #expect(ImageUtils.loadReceiptImage(relativePath: page.localImagePath) != nil,
                "the bytes must be readable back off disk")
    }

    /// Once a receipt has been opened, its list row should stop showing a
    /// placeholder glyph.
    @Test
    func generatesAThumbnailSoTheListRowFillsIn() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        installDownloadHandler(bytes: try Self.jpegBytes())

        try await h.downloader.downloadMissingImages(for: receipt)

        let page = try #require(receipt.pages.first)
        let thumbPath = ImageUtils.thumbnailPath(for: page.localImagePath)
        #expect(ImageUtils.loadReceiptImage(relativePath: thumbPath) != nil)
    }

    @Test
    func skipsPagesThatAlreadyHaveTheirBytes() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        installDownloadHandler(bytes: try Self.jpegBytes())
        try await h.downloader.downloadMissingImages(for: receipt)

        let counter = Counter()
        installCountingHandler(counter)
        try await h.downloader.downloadMissingImages(for: receipt)

        #expect(counter.count == 0, "a page with bytes on disk must not be re-fetched")
    }

    @Test
    func skipsPagesWithNoServerObject() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context, serverFilePath: nil)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }

        let counter = Counter()
        installCountingHandler(counter)
        try await h.downloader.downloadMissingImages(for: receipt)

        #expect(counter.count == 0)
    }

    @Test
    func aFailedDownloadLeavesThePageMarkedMissing() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }

        await #expect(throws: (any Error).self) {
            try await h.downloader.downloadMissingImages(for: receipt)
        }

        let page = try #require(receipt.pages.first)
        #expect(page.imageDownloaded == false, "a failed download must stay retryable")
        #expect(page.imageDownloadedAt == nil)
    }

    @Test
    func downloadsAPDFPageAndRendersItsThumbnail() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(
            in: h.context, serverFilePath: "tenants/a/one.pdf", contentType: .pdf
        )
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        installDownloadHandler(bytes: try Self.pdfBytes())

        try await h.downloader.downloadMissingImages(for: receipt)

        let page = try #require(receipt.pages.first)
        #expect(page.imageDownloaded == true)
        #expect(ImageUtils.pdfPageCount(relativePath: page.localImagePath) == 1)
        let thumbPath = ImageUtils.thumbnailPath(for: page.localImagePath)
        #expect(ImageUtils.loadReceiptImage(relativePath: thumbPath) != nil)
    }

    /// A cleaned-up local capture is re-downloadable; the flag that drove the
    /// permanent "Images Removed" dead end has to clear.
    @Test
    func aSuccessfulDownloadClearsTheImagesCleanedUpFlag() async throws {
        let h = try makeHarness()
        let receipt = try makeRemoteReceipt(in: h.context)
        defer { ImageUtils.deleteReceiptImages(receiptId: receipt.id) }
        receipt.imagesCleanedUp = true
        try h.context.save()
        installDownloadHandler(bytes: try Self.jpegBytes())

        try await h.downloader.downloadMissingImages(for: receipt)

        #expect(receipt.imagesCleanedUp == false)
    }
}

} // MockURLProtocolSuites
