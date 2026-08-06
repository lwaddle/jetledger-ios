//
//  ReceiptDetailContentTests.swift
//  JetLedgerTests
//
//  Covers the rules that decide whether a receipt's images can still be
//  recovered, and what an image-less receipt is allowed to say.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

@MainActor
@Suite
struct ReceiptDetailContentTests {

    /// Returns the container too: `ModelContext` does not retain it, and a model
    /// whose container has been deallocated traps on access.
    private struct Harness {
        let context: ModelContext
        let container: ModelContainer
    }

    private func makeHarness() throws -> Harness {
        let schema = Schema([
            LocalReceipt.self, LocalReceiptPage.self,
            CachedAccount.self, CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return Harness(context: container.mainContext, container: container)
    }

    @discardableResult
    private func makeReceipt(
        in harness: Harness,
        serverReceiptId: UUID? = UUID(),
        detailFetchedAt: Date? = nil,
        imageCount: Int = 1,
        pages: [(downloaded: Bool, serverFilePath: String?)] = []
    ) -> LocalReceipt {
        let receipt = LocalReceipt(
            accountId: UUID(), capturedAt: Date(), syncStatus: .uploaded
        )
        receipt.serverReceiptId = serverReceiptId
        receipt.detailFetchedAt = detailFetchedAt
        receipt.imageCount = imageCount
        harness.context.insert(receipt)
        for (index, spec) in pages.enumerated() {
            let page = LocalReceiptPage(
                sortOrder: index, localImagePath: "receipts/x/page-00\(index + 1).jpg"
            )
            page.imageDownloaded = spec.downloaded
            page.serverFilePath = spec.serverFilePath
            harness.context.insert(page)
            page.receipt = receipt
        }
        return receipt
    }

    // MARK: - needsDetailFetch

    @Test
    func aReceiptWhoseDetailWasNeverFetchedNeedsAFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, detailFetchedAt: nil, pages: [(true, nil)])
        #expect(ReceiptDetailContent.needsDetailFetch(receipt))
    }

    /// The dead end this task exists to close: detail was fetched once, the
    /// pages never got a serverFilePath out of it, so the downloader skips them
    /// forever and the old condition never refetched.
    @Test
    func aPageMissingBytesAndAFilePathForcesAnotherDetailFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(false, nil)]
        )
        #expect(ReceiptDetailContent.needsDetailFetch(receipt),
                "a page with no bytes and no file path must refetch to learn where its bytes live")
    }

    @Test
    func aPageMissingBytesButKnowingItsFilePathDoesNotRefetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(false, "r2/key.jpg")]
        )
        #expect(!ReceiptDetailContent.needsDetailFetch(receipt),
                "the downloader can already act on this — no second detail request")
    }

    @Test
    func aReceiptWithItsBytesOnDiskDoesNotRefetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(true, "r2/key.jpg")]
        )
        #expect(!ReceiptDetailContent.needsDetailFetch(receipt))
    }

    /// The server says there are images and this row has no page records to
    /// download into. Refetching is the only way to get them.
    @Test
    func aRowWithNoPagesButAServerImageCountRefetches() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), imageCount: 2, pages: []
        )
        #expect(ReceiptDetailContent.needsDetailFetch(receipt))
    }

    @Test
    func aRowWithNoPagesAndNoServerImagesDoesNotRefetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), imageCount: 0, pages: []
        )
        #expect(!ReceiptDetailContent.needsDetailFetch(receipt),
                "there is nothing to fetch — refetching on every open would be a loop")
    }

    // MARK: - emptyState

    /// Online with a server record, we should have downloaded and did not.
    /// That is a failure the user can retry, not a fact about disk space.
    @Test
    func onlineWithAServerRecordTheEmptyStateIsRetryable() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, pages: [(false, "r2/key.jpg")])
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: true) == .retryable)
    }

    @Test
    func offlineTheEmptyStateBlamesConnectivity() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, pages: [(false, "r2/key.jpg")])
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: false) == .offline)
    }

    /// Nothing was ever uploaded, so there is genuinely nothing to fetch.
    @Test
    func aReceiptWithNoServerRecordHasNothingToFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, serverReceiptId: nil, pages: [(false, nil)])
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: true) == .noImage)
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: false) == .noImage)
    }

    /// Detail was fetched and the server reported no images at all. Offering a
    /// Try Again button here would promise something that cannot happen.
    @Test
    func aFetchedReceiptTheServerHasNoImagesForIsNotRetryable() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), imageCount: 0, pages: []
        )
        #expect(ReceiptDetailContent.emptyState(for: receipt, isConnected: true) == .noImage)
    }

    // MARK: - shouldAttemptFetch

    /// The rule that keeps the offline empty state reachable: attempting the
    /// network call offline would fail with a raw URLError and set
    /// imageLoadError, whose branch outranks the purpose-built offline copy.
    /// A receipt that would otherwise need a fetch (fresh detail, missing
    /// bytes) must still be refused while disconnected.
    @Test
    func offlineDoesNotAttemptAFetchRegardlessOfReceiptState() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: nil, pages: [(false, "r2/key.jpg")]
        )
        #expect(!ReceiptDetailContent.shouldAttemptFetch(receipt, isConnected: false))
    }

    /// Nothing was ever uploaded — connectivity can't fetch a receipt that
    /// has no server record to ask about.
    @Test
    func connectedWithNoServerRecordDoesNotAttemptAFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(in: harness, serverReceiptId: nil, pages: [(false, nil)])
        #expect(!ReceiptDetailContent.shouldAttemptFetch(receipt, isConnected: true))
    }

    /// Detail is current and every page already has bytes on disk — a fetch
    /// would accomplish nothing, folding in the old needsPages/needsBytes guard.
    @Test
    func connectedWithNothingMissingDoesNotAttemptAFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(true, "r2/key.jpg")]
        )
        #expect(!ReceiptDetailContent.shouldAttemptFetch(receipt, isConnected: true))
    }

    @Test
    func connectedAndNeedingDetailAttemptsAFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: nil, pages: [(true, "r2/key.jpg")]
        )
        #expect(ReceiptDetailContent.shouldAttemptFetch(receipt, isConnected: true))
    }

    /// Detail is current but a page still lacks bytes — needsDetailFetch is
    /// false here (the file path is known) yet a download is still owed.
    @Test
    func connectedAndNeedingBytesOnlyAttemptsAFetch() throws {
        let harness = try makeHarness()
        let receipt = makeReceipt(
            in: harness, detailFetchedAt: Date(), pages: [(false, "r2/key.jpg")]
        )
        #expect(ReceiptDetailContent.shouldAttemptFetch(receipt, isConnected: true))
    }
}
