//
//  SyncServiceRetryTests.swift
//  JetLedgerTests
//
//  Covers the upload queue's failure model: automatic retry with exponential
//  backoff, permanent-failure parking, 401 handling, resumed partial uploads,
//  and the status-sync edge cases (receipt deleted on web, duplicate IDs).
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

/// Thread-safe request recorder — MockURLProtocol's handler runs on URLSession's
/// background queue.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(method: String, path: String, body: Data?)] = []

    func record(_ request: URLRequest) {
        let entry = (
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            body: request.bodyBytes
        )
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [(method: String, path: String, body: Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private extension URLRequest {
    /// URLProtocol receives POST bodies as a stream, not `httpBody`.
    var bodyBytes: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// Nested inside MockURLProtocolSuites: the mock handler is a process-wide
// static, so every suite that touches it must serialize against the others.
extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct SyncServiceRetryTests {

    init() {
        MockURLProtocol.reset()
    }

    // MARK: - Harness

    private struct Harness {
        let sync: SyncService
        let context: ModelContext
        let container: ModelContainer
        let monitor: NetworkMonitor
    }

    private func makeHarness(isConnected: Bool = true) throws -> Harness {
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
        monitor.setConnectedForTesting(isConnected)
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
        return Harness(sync: sync, context: context, container: container, monitor: monitor)
    }

    /// Inserts a one-page receipt. `fileBytes > 0` writes a real page file to
    /// Documents (uploadReceipt reads it from disk).
    @discardableResult
    private func makeReceipt(
        in context: ModelContext,
        status: SyncStatus,
        retryCount: Int = 0,
        nextRetryAfter: Date? = nil,
        r2ImagePath: String? = nil,
        r2GrantedAt: Date? = nil,
        capturedAt: Date = Date(),
        fileBytes: Int = 1234
    ) throws -> LocalReceipt {
        let receiptId = UUID()
        let relativePath = "receipts/\(receiptId.uuidString)/page-000.jpg"
        if fileBytes > 0 {
            let dir = ImageUtils.documentsDirectory()
                .appendingPathComponent("receipts/\(receiptId.uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: fileBytes)
                .write(to: dir.appendingPathComponent("page-000.jpg"))
        }
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
        receipt.retryCount = retryCount
        receipt.nextRetryAfter = nextRetryAfter
        context.insert(receipt)
        page.receipt = receipt
        context.insert(page)
        try context.save()
        return receipt
    }

    private func removeFiles(for receipt: LocalReceipt) {
        ImageUtils.deleteReceiptImages(receiptId: receipt.id)
    }

    /// Routes the full happy-path upload conversation and records every request.
    private func installSuccessHandler(log: RequestLog) {
        MockURLProtocol.handler = { request in
            log.record(request)
            let url = request.url!
            let ok = { (json: String) in
                (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                 json.data(using: .utf8)!)
            }
            switch url.path {
            case "/api/receipts/upload-url":
                return ok(#"{"upload_url":"https://example.test/r2/page-000.jpg","file_path":"stored/page-000.jpg"}"#)
            case let p where p.hasPrefix("/r2/"):
                return ok("{}")
            case "/api/receipts":
                return ok(#"{"id":"\#(UUID().uuidString.lowercased())","status":"pending","created_at":"2026-07-14T00:00:00Z"}"#)
            default:
                return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        #"{"error":"unexpected route"}"#.data(using: .utf8)!)
            }
        }
    }

    // MARK: - Backoff & auto-retry

    @Test
    func transientFailureSetsFailedStatusWithExponentialBackoff() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .queued)
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .failed)
        #expect(receipt.retryCount == 1)
        let retryAt = try #require(receipt.nextRetryAfter)
        // 2^1 * 30s = 60s, allow scheduling slack
        let delay = retryAt.timeIntervalSinceNow
        #expect(delay > 50 && delay < 70)
        #expect(h.sync.lastError != nil)
    }

    @Test
    func failedReceiptInBackoffIsNotRetried() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, status: .failed,
            retryCount: 1, nextRetryAfter: Date().addingTimeInterval(3600)
        )
        defer { removeFiles(for: receipt) }
        let log = RequestLog()
        installSuccessHandler(log: log)

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(log.all.isEmpty, "receipt still in backoff must not hit the network")
        #expect(receipt.syncStatus == .failed)
        #expect(receipt.retryCount == 1)
    }

    @Test
    func failedReceiptWithElapsedBackoffAutoRetriesAndUploads() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, status: .failed,
            retryCount: 2, nextRetryAfter: Date().addingTimeInterval(-10)
        )
        defer { removeFiles(for: receipt) }
        let log = RequestLog()
        installSuccessHandler(log: log)

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .uploaded)
        #expect(receipt.serverReceiptId != nil)
        #expect(receipt.serverStatus == .pending)
        #expect(receipt.retryCount == 0)
        #expect(receipt.nextRetryAfter == nil)
        let paths = log.all.map(\.path)
        #expect(paths.contains("/api/receipts/upload-url"))
        #expect(paths.contains("/r2/page-000.jpg"))
        #expect(paths.contains("/api/receipts"))
    }

    @Test
    func permanentFailureParksAtDistantFuture() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .queued)
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!,
             #"{"error":"file too large"}"#.data(using: .utf8)!)
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .failed)
        #expect(receipt.nextRetryAfter == Date.distantFuture,
                "413 can never succeed on retry — must park, not backoff-loop")
    }

    @Test
    func manualRetryClearsParkedBackoff() async throws {
        // Offline harness: retryReceipt's processQueue no-ops so we can assert
        // the requeue state without a network round-trip.
        let h = try makeHarness(isConnected: false)
        let receipt = try makeReceipt(
            in: h.context, status: .failed,
            retryCount: 3, nextRetryAfter: .distantFuture, fileBytes: 0
        )

        h.sync.retryReceipt(receipt)

        #expect(receipt.syncStatus == .queued)
        #expect(receipt.retryCount == 0)
        #expect(receipt.nextRetryAfter == nil)
    }

    // MARK: - 401 handling

    @Test
    func unauthorizedRevertsToQueuedAndStopsTheQueue() async throws {
        let h = try makeHarness()
        let first = try makeReceipt(
            in: h.context, status: .queued,
            capturedAt: Date().addingTimeInterval(-60)
        )
        let second = try makeReceipt(in: h.context, status: .queued)
        defer {
            removeFiles(for: first)
            removeFiles(for: second)
        }
        let log = RequestLog()
        MockURLProtocol.handler = { request in
            log.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    #"{"error":"invalid token"}"#.data(using: .utf8)!)
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(first.syncStatus == .queued, "401 must revert to queued, not failed")
        #expect(first.nextRetryAfter == nil)
        #expect(second.syncStatus == .queued)
        #expect(log.all.count == 1,
                "queue must stop at the first 401 instead of hammering every receipt")
    }

    // MARK: - Resumed partial uploads

    @Test
    func resumedUploadSkipsUploadedPageAndSendsRealFileSize() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, status: .queued,
            r2ImagePath: "stored/page-000.jpg",
            r2GrantedAt: Date(),
            fileBytes: 1234
        )
        defer { removeFiles(for: receipt) }
        let log = RequestLog()
        installSuccessHandler(log: log)

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .uploaded)
        let paths = log.all.map(\.path)
        #expect(!paths.contains("/api/receipts/upload-url"),
                "already-uploaded page must not request a new presigned URL")
        #expect(!paths.contains { $0.hasPrefix("/r2/") },
                "already-uploaded page must not re-upload to R2")

        let create = try #require(log.all.first { $0.path == "/api/receipts" })
        let body = try #require(create.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        let fileSize = try #require(images.first?["file_size"] as? Int)
        #expect(fileSize == 1234, "resumed pages must report their real size, not 0")
    }

    // MARK: - Stalled-upload surfacing

    /// A red badge looks the same after five minutes and after five days, so a
    /// permanently stuck receipt reads as a transient one. The stamp is what
    /// lets the UI tell them apart.
    @Test
    func firstFailureStampsTheReceiptAndRepeatFailuresKeepTheOriginalStamp() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .queued)
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()
        let firstStamp = try #require(receipt.firstFailedAt)

        receipt.nextRetryAfter = nil
        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.retryCount == 2, "the second attempt must have run")
        #expect(receipt.firstFailedAt == firstStamp,
                "the stamp marks when trouble started, not the latest attempt")
    }

    @Test
    func successClearsTheFailureStamp() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, status: .failed,
            retryCount: 2, nextRetryAfter: Date().addingTimeInterval(-10)
        )
        receipt.firstFailedAt = Date().addingTimeInterval(-48 * 3600)
        try h.context.save()
        defer { removeFiles(for: receipt) }
        let log = RequestLog()
        installSuccessHandler(log: log)

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .uploaded)
        #expect(receipt.firstFailedAt == nil, "a receipt that uploaded is not stalled")
    }

    @Test
    func onlyLongRunningFailuresCountAsStalled() async throws {
        let h = try makeHarness(isConnected: false)
        let recent = try makeReceipt(in: h.context, status: .failed, fileBytes: 0)
        recent.firstFailedAt = Date().addingTimeInterval(-30 * 60)
        let stalled = try makeReceipt(in: h.context, status: .failed, fileBytes: 0)
        stalled.firstFailedAt = Date().addingTimeInterval(-36 * 3600)
        let queued = try makeReceipt(in: h.context, status: .queued, fileBytes: 0)
        queued.firstFailedAt = Date().addingTimeInterval(-36 * 3600)
        try h.context.save()

        #expect(!recent.isStalled, "a 30-minute-old failure is still plausibly a blip")
        #expect(stalled.isStalled)
        #expect(!queued.isStalled,
                "a receipt that has gone back to queued is retrying, not stalled")
    }

    /// MainView alerts on `lastError` *changing*. Left set after a recovery, an
    /// identical next failure is a no-op change and the user is never told.
    @Test
    func successClearsLastErrorSoTheNextFailureStillAlerts() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, status: .failed,
            retryCount: 1, nextRetryAfter: Date().addingTimeInterval(-10)
        )
        defer { removeFiles(for: receipt) }
        h.sync.lastError = "Upload failed with status 500."
        let log = RequestLog()
        installSuccessHandler(log: log)

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .uploaded)
        #expect(h.sync.lastError == nil,
                "a stale error would suppress the alert for the next real failure")
    }

    // MARK: - Expired grants

    /// An upload URL is not a reservation: the server deletes any unclaimed
    /// object 24h after granting it. A stored path older than that names an
    /// object that no longer exists, so claiming it can only ever 400.
    @Test
    func grantPastTheReapWindowIsReuploadedInsteadOfClaimed() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, status: .queued,
            r2ImagePath: "stored/expired.jpg",
            r2GrantedAt: Date().addingTimeInterval(-25 * 3600),
            fileBytes: 1234
        )
        defer { removeFiles(for: receipt) }
        let log = RequestLog()
        installSuccessHandler(log: log)

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        let paths = log.all.map(\.path)
        #expect(paths.contains("/api/receipts/upload-url"),
                "an expired grant must be re-requested, not reused")
        #expect(paths.contains("/r2/page-000.jpg"), "the local image must be re-uploaded")
        #expect(receipt.syncStatus == .uploaded)

        let create = try #require(log.all.first { $0.path == "/api/receipts" })
        let body = try #require(create.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let images = try #require(json["images"] as? [[String: Any]])
        #expect(images.first?["file_path"] as? String == "stored/page-000.jpg",
                "the create must claim the fresh path, never the expired one")
    }

    /// Rows written before grant timestamps existed have no age to check. The
    /// safe reading is "possibly expired" — re-uploading costs one request,
    /// claiming a reaped path loses the receipt permanently.
    @Test
    func grantWithoutATimestampIsTreatedAsExpired() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(
            in: h.context, status: .queued,
            r2ImagePath: "stored/legacy.jpg",
            r2GrantedAt: nil,
            fileBytes: 1234
        )
        defer { removeFiles(for: receipt) }
        let log = RequestLog()
        installSuccessHandler(log: log)

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(log.all.map(\.path).contains("/api/receipts/upload-url"),
                "a grant of unknown age must be re-requested")
        #expect(receipt.syncStatus == .uploaded)
    }

    // MARK: - Create-time 400s

    /// 400 "uploaded image not found" means the object is gone. Retrying the
    /// same path can never succeed — the stored grant must be dropped so the
    /// next attempt re-uploads the local file the app still holds.
    @Test
    func uploadedImageNotFoundDropsTheGrantAndStaysRetryable() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .queued)
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { request in
            let url = request.url!
            switch url.path {
            case "/api/receipts":
                return (HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        #"{"error":"uploaded image not found"}"#.data(using: .utf8)!)
            case "/api/receipts/upload-url":
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"upload_url":"https://example.test/r2/page-000.jpg","file_path":"stored/page-000.jpg"}"#.data(using: .utf8)!)
            default:
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .failed)
        #expect(receipt.pages.first?.r2ImagePath == nil,
                "a missing object's path must be cleared so the retry re-uploads")
        #expect(receipt.nextRetryAfter != .distantFuture,
                "re-uploading can succeed — this must not park as permanent")
    }

    /// 400 "... exceeds max size" is permanent AND the server deletes the
    /// object, so the dead path must not be left behind for a manual retry to
    /// claim.
    @Test
    func oversizeOnCreateParksPermanentlyAndDropsTheGrant() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .queued)
        defer { removeFiles(for: receipt) }
        MockURLProtocol.handler = { request in
            let url = request.url!
            switch url.path {
            case "/api/receipts":
                return (HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        #"{"error":"image stored/page-000.jpg exceeds max size"}"#.data(using: .utf8)!)
            case "/api/receipts/upload-url":
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{"upload_url":"https://example.test/r2/page-000.jpg","file_path":"stored/page-000.jpg"}"#.data(using: .utf8)!)
            default:
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(receipt.syncStatus == .failed)
        #expect(receipt.nextRetryAfter == .distantFuture,
                "an oversized image can never be claimed — park it")
        #expect(receipt.pages.first?.r2ImagePath == nil,
                "the server deleted the object; the path must not survive")
    }

    /// The grant endpoint can now fail before any URL is issued. Proceeding to
    /// the PUT would upload to a URL that was never granted.
    @Test
    func grantFailureNeverReachesTheUpload() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .queued)
        defer { removeFiles(for: receipt) }
        let log = RequestLog()
        MockURLProtocol.handler = { request in
            log.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    #"{"error":"failed to prepare upload"}"#.data(using: .utf8)!)
        }

        h.sync.processQueue()
        await h.sync.waitForQueueDrain()

        #expect(!log.all.map(\.path).contains { $0.hasPrefix("/r2/") },
                "a failed grant must not be followed by an upload")
        #expect(!log.all.map(\.path).contains("/api/receipts"))
        #expect(receipt.syncStatus == .failed)
        #expect(receipt.retryCount == 1)
        #expect(receipt.nextRetryAfter != .distantFuture, "a 500 is retryable")
    }

    // MARK: - Delete

    @Test
    func deleteToleratesAlreadyDeletedServerSide() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded, fileBytes: 0)
        receipt.serverReceiptId = UUID()
        try h.context.save()
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{"error":"not found"}"#.data(using: .utf8)!)
        }

        try await h.sync.deleteReceipt(receipt)

        let remaining = try h.context.fetch(FetchDescriptor<LocalReceipt>())
        #expect(remaining.isEmpty, "a server-side 404 must not block local deletion")
    }

    // MARK: - Status sync

    @Test
    func statusSyncMarksReceiptAbsentFromResponseAsRemoved() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded, fileBytes: 0)
        receipt.serverReceiptId = UUID()
        receipt.serverStatus = .pending
        try h.context.save()
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             #"{"receipts":[]}"#.data(using: .utf8)!)
        }

        await h.sync.syncReceiptStatuses()

        #expect(receipt.serverStatus == .rejected)
        #expect(receipt.rejectionReason?.contains("Removed") == true)
        #expect(receipt.terminalStatusAt != nil,
                "absent receipts must become terminal so retention reclaims them")
    }

    @Test
    func statusSyncToleratesDuplicateIdsInResponse() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded, fileBytes: 0)
        let serverId = UUID()
        receipt.serverReceiptId = serverId
        receipt.serverStatus = .pending
        try h.context.save()
        let id = serverId.uuidString.lowercased()
        MockURLProtocol.handler = { request in
            // Duplicated entry: Dictionary(uniqueKeysWithValues:) would trap here.
            let body = #"{"receipts":[{"id":"\#(id)","status":"processed","expense_id":null,"rejection_reason":null},{"id":"\#(id)","status":"processed","expense_id":null,"rejection_reason":null}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }

        await h.sync.syncReceiptStatuses()

        #expect(receipt.serverStatus == .processed)
        #expect(receipt.terminalStatusAt != nil)
    }

    // MARK: - Local removal of rejected receipts

    @Test
    func dismissRejectedReceiptHidesItLocallyWithoutNetwork() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded)
        receipt.serverReceiptId = UUID()
        receipt.serverStatus = .rejected
        try h.context.save()
        let imageDir = ImageUtils.documentsDirectory()
            .appendingPathComponent("receipts/\(receipt.id.uuidString)")
        let log = RequestLog()
        MockURLProtocol.handler = { request in
            log.record(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data())
        }

        h.sync.dismissRejectedReceipt(receipt)

        #expect(receipt.dismissedAt != nil)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "the row must survive so the next page fetch doesn't resurrect it")
        #expect(!FileManager.default.fileExists(atPath: imageDir.path))
        #expect(log.all.isEmpty, "server record must survive — deletion is an admin decision on the web")
    }

    @Test
    func dismissRejectedReceiptIgnoresNonRejectedReceipts() async throws {
        let h = try makeHarness()
        let receipt = try makeReceipt(in: h.context, status: .uploaded)
        receipt.serverStatus = .pending
        try h.context.save()
        defer { removeFiles(for: receipt) }

        h.sync.dismissRejectedReceipt(receipt)

        #expect(receipt.dismissedAt == nil)
    }
}

} // MockURLProtocolSuites
