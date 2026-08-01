//
//  SyncServiceTermsTests.swift
//  JetLedgerTests
//
//  A terms-gate 403 on a queued upload is retryable-after-acceptance: the
//  receipt parks as .queued (no "Failed" badge, no stalled banner, grants
//  kept) and the queue pass stops. A landing-time sync can hit the backstop
//  moments before the app learns to show the gate, so parking must never read
//  as failure.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

/// Thread-safe request recorder — the mock handler runs on URLSession's queue.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ request: URLRequest) {
        lock.lock()
        paths.append(request.url?.path ?? "")
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

// Nested inside MockURLProtocolSuites: the mock handler is a process-wide
// static, so every suite that touches it must serialize against the others.
extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct SyncServiceTermsTests {

    init() {
        MockURLProtocol.reset()
    }

    /// nonisolated: referenced inside MockURLProtocol handlers, which run on
    /// URLSession's background queue.
    private nonisolated static let termsGateBody = """
    {"error": "terms_acceptance_required",
     "message": "The JetLedger Terms of Service have been updated and must be accepted before continuing.",
     "terms_version": "2026-07-31",
     "terms_url": "https://jetledger.io/terms"}
    """.data(using: .utf8)!

    // MARK: - Harness

    private struct Harness {
        let sync: SyncService
        let apiClient: APIClient
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
        let context = container.mainContext
        let monitor = NetworkMonitor()
        monitor.setConnectedForTesting(true)
        let apiClient = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        let sync = SyncService(
            receiptAPI: ReceiptAPIService(apiClient: apiClient),
            r2Upload: R2UploadService(session: MockURLProtocol.makeSession()),
            networkMonitor: monitor,
            modelContext: context
        )
        return Harness(sync: sync, apiClient: apiClient, context: context, container: container)
    }

    @discardableResult
    private func makeReceipt(
        in context: ModelContext,
        status: SyncStatus = .queued,
        r2ImagePath: String? = nil,
        r2GrantedAt: Date? = nil,
        capturedAt: Date = Date()
    ) throws -> LocalReceipt {
        let receiptId = UUID()
        let relativePath = "receipts/\(receiptId.uuidString)/page-000.jpg"
        let dir = ImageUtils.documentsDirectory()
            .appendingPathComponent("receipts/\(receiptId.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 1234)
            .write(to: dir.appendingPathComponent("page-000.jpg"))
        let page = LocalReceiptPage(sortOrder: 0, localImagePath: relativePath)
        page.r2ImagePath = r2ImagePath
        page.r2GrantedAt = r2GrantedAt
        let receipt = LocalReceipt(
            id: receiptId,
            accountId: UUID(),
            capturedAt: capturedAt,
            syncStatus: status,
            pages: [page]
        )
        context.insert(receipt)
        page.receipt = receipt
        context.insert(page)
        try context.save()
        return receipt
    }

    private func removeFiles(for receipt: LocalReceipt) {
        ImageUtils.deleteReceiptImages(receiptId: receipt.id)
    }

    // MARK: - Upload parking

    @Test
    func termsGate403ParksReceiptsAsQueuedAndStopsTheQueue() async throws {
        let h = try makeHarness()
        let first = try makeReceipt(in: h.context, capturedAt: Date().addingTimeInterval(-60))
        let second = try makeReceipt(in: h.context)
        defer {
            removeFiles(for: first)
            removeFiles(for: second)
        }
        let log = RequestLog()
        MockURLProtocol.handler = { request in
            log.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Self.termsGateBody)
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(first.syncStatus == .queued, "parked-on-terms must read as waiting, not failed")
        #expect(first.firstFailedAt == nil,
                "the stalled banner must never escalate a receipt the gate is holding")
        #expect(first.retryCount == 0)
        #expect(first.nextRetryAfter == nil)
        #expect(second.syncStatus == .queued)
        #expect(log.all.count == 1,
                "the whole session is gated — the queue must stop, not 403 every receipt")
        #expect(h.sync.lastError == nil,
                "the gate UI is the report; an Upload Error alert would double-report it")
    }

    @Test
    func termsGate403OnTheCreatePreservesStoredGrants() async throws {
        let h = try makeHarness()
        let grantedAt = Date().addingTimeInterval(-3600)
        let receipt = try makeReceipt(
            in: h.context,
            r2ImagePath: "stored/page-000.jpg",
            r2GrantedAt: grantedAt
        )
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Self.termsGateBody)
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .queued)
        #expect(receipt.pages.first?.r2ImagePath == "stored/page-000.jpg",
                "the object is still in R2 — clearing the grant would re-upload for nothing")
        #expect(receipt.pages.first?.r2GrantedAt == grantedAt,
                "grant expiry runs on its own clock, not on the gate's")
    }

    /// Guards the exact-match boundary inside the queue: a plain permission
    /// 403 keeps its existing permanent-park behavior.
    @Test
    func ordinaryForbidden403StillParksPermanently() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context)
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             #"{"error":"insufficient permissions"}"#.data(using: .utf8)!)
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .failed)
        #expect(receipt.nextRetryAfter == Date.distantFuture,
                "a role-based 403 cannot succeed on retry — must still park")
    }

    // MARK: - Status sync

    @Test
    func statusSyncStopsQuietlyBehindTheTermsGate() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded)
        receipt.serverReceiptId = UUID()
        receipt.serverStatus = .pending
        try h.context.save()
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Self.termsGateBody)
        }

        await h.sync.syncReceiptStatuses()

        #expect(receipt.serverStatus == .pending, "a gated poll must not invent a status")
        #expect(h.sync.lastError == nil)
    }

    // MARK: - APIClient classification

    @Test
    func apiClientFiresTheGateCallbackAndThrowsTheTypedError() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Self.termsGateBody)
        }
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        var received: TermsRequiredPayload?
        client.onTermsAcceptanceRequired = { received = $0 }

        await #expect(throws: APIError.termsAcceptanceRequired) {
            try await client.requestVoid(.get, "/api/receipts")
        }

        #expect(received?.termsVersion == "2026-07-31")
        #expect(received?.termsUrl == "https://jetledger.io/terms")
    }

    @Test
    func ordinary403DoesNotFireTheGateCallback() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             #"{"error":"insufficient permissions"}"#.data(using: .utf8)!)
        }
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        var fired = false
        client.onTermsAcceptanceRequired = { _ in fired = true }

        await #expect(throws: APIError.forbidden) {
            try await client.requestVoid(.get, "/api/receipts")
        }

        #expect(!fired)
    }
}

} // MockURLProtocolSuites
