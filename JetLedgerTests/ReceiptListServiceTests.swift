//
//  ReceiptListServiceTests.swift
//  JetLedgerTests
//
//  Covers the list/detail API surface and the paging state machine on top of it.
//

import Testing
import Foundation
import SwiftData
@testable import JetLedger

/// Thread-safe request recorder — MockURLProtocol's handler runs on URLSession's
/// background queue.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(method: String, path: String, query: String?)] = []

    func record(_ request: URLRequest) {
        let entry = (
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            query: request.url?.query
        )
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [(method: String, path: String, query: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

extension MockURLProtocolSuites {

@MainActor
@Suite(.serialized)
struct ReceiptListServiceTests {

    init() {
        MockURLProtocol.reset()
    }

    // MARK: - Harness

    private func makeAPI() -> ReceiptAPIService {
        ReceiptAPIService(apiClient: APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        ))
    }

    private func respond(_ json: String, log: RequestLog? = nil) {
        MockURLProtocol.handler = { request in
            log?.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json.data(using: .utf8)!
            )
        }
    }

    // MARK: - Decoding

    @Test
    func decodesAFullListRow() async throws {
        let api = makeAPI()
        respond("""
        {"receipts":[{
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"rejected",
          "source":"email",
          "note":"Fwd: Signature Flight Support receipt",
          "trip_reference_id":"3a7e0000-0000-4000-8000-000000000002",
          "ocr_status":"completed",
          "rejection_reason":"unreadable",
          "expense_id":"",
          "image_count":1,
          "created_at":"2026-07-27 14:03:22",
          "updated_at":"2026-07-27 15:11:08"
        }],"total":137,"limit":25,"offset":0}
        """)

        let response = try await api.listReceipts(
            status: nil, limit: 25, offset: 0, accountId: UUID()
        )

        #expect(response.total == 137)
        #expect(response.receipts.count == 1)
        let row = try #require(response.receipts.first)
        #expect(row.status == "rejected")
        #expect(row.source == "email")
        #expect(row.note == "Fwd: Signature Flight Support receipt")
        #expect(row.ocrStatus == "completed")
        #expect(row.rejectionReason == "unreadable")
        #expect(row.imageCount == 1)
        #expect(ServerDateFormatter.date(from: row.createdAt) != nil)
    }

    /// The server omits these keys entirely rather than sending null. A
    /// non-optional property would fail the whole page decode.
    @Test
    func decodesARowWithEveryOmitemptyKeyAbsent() async throws {
        let api = makeAPI()
        respond("""
        {"receipts":[{
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"pending",
          "source":"ios",
          "ocr_status":"pending",
          "image_count":2,
          "created_at":"2026-07-27 14:03:22",
          "updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)

        let response = try await api.listReceipts(
            status: nil, limit: 25, offset: 0, accountId: UUID()
        )

        let row = try #require(response.receipts.first)
        #expect(row.note == nil)
        #expect(row.tripReferenceId == nil)
        #expect(row.rejectionReason == nil)
        #expect(row.expenseId == nil)
    }

    /// The contract calls these fields `omitempty`, yet its own example payload
    /// sends `"expense_id": ""`. Strict `UUID?` decoding throws on that, and one
    /// bad field fails the whole page — every receipt disappears because one has
    /// no expense yet.
    @Test
    func emptyStringUUIDFieldsDecodeAsAbsentRatherThanFailingThePage() async throws {
        let api = makeAPI()
        respond("""
        {"receipts":[{
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"pending","source":"ios","ocr_status":"pending",
          "expense_id":"","trip_reference_id":"",
          "image_count":1,
          "created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)

        let response = try await api.listReceipts(
            status: nil, limit: 25, offset: 0, accountId: UUID()
        )

        #expect(response.receipts.count == 1, "one empty field must not drop the page")
        let row = try #require(response.receipts.first)
        #expect(row.expenseId == nil)
        #expect(row.tripReferenceId == nil)
    }

    /// Go's `omitempty` drops a zero int, so a receipt with no images can arrive
    /// without the key at all.
    @Test
    func aMissingImageCountDefaultsToZero() async throws {
        let api = makeAPI()
        respond("""
        {"receipts":[{
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"pending","source":"email","ocr_status":"pending",
          "created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)

        let response = try await api.listReceipts(
            status: nil, limit: 25, offset: 0, accountId: UUID()
        )

        #expect(try #require(response.receipts.first).imageCount == 0)
    }

    @Test
    func decodesDetailWithImages() async throws {
        let api = makeAPI()
        respond("""
        {
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"rejected",
          "source":"email",
          "ocr_status":"completed",
          "rejection_reason":"unreadable",
          "image_count":1,
          "created_at":"2026-07-27 14:03:22",
          "updated_at":"2026-07-27 15:11:08",
          "images":[{
            "id":"b21d0000-0000-4000-8000-000000000003",
            "file_path":"tenants/acct/staged_receipts/2026/07/b21d.jpg",
            "file_name":"IMG_4417.jpg",
            "mime_type":"image/jpeg",
            "sort_order":0
          }]
        }
        """)

        let detail = try await api.getReceipt(
            id: UUID(uuidString: "9f1c0000-0000-4000-8000-000000000001")!,
            accountId: UUID()
        )

        #expect(detail.images.count == 1)
        let image = try #require(detail.images.first)
        #expect(image.filePath == "tenants/acct/staged_receipts/2026/07/b21d.jpg")
        #expect(image.fileName == "IMG_4417.jpg")
        #expect(image.mimeType == "image/jpeg")
        #expect(image.sortOrder == 0)
    }

    /// The detail payload is flat — the row's fields sit beside `images` — and
    /// the summary is decoded out of that same container rather than restated.
    @Test
    func decodesTheRowFieldsOfADetailPayload() async throws {
        let api = makeAPI()
        respond("""
        {
          "id":"9f1c0000-0000-4000-8000-000000000001",
          "status":"rejected",
          "source":"email",
          "note":"Fwd: fuel",
          "ocr_status":"completed",
          "rejection_reason":"unreadable",
          "image_count":1,
          "created_at":"2026-07-27 14:03:22",
          "updated_at":"2026-07-27 15:11:08",
          "images":[]
        }
        """)

        let detail = try await api.getReceipt(
            id: UUID(uuidString: "9f1c0000-0000-4000-8000-000000000001")!,
            accountId: UUID()
        )

        #expect(detail.summary.status == "rejected")
        #expect(detail.summary.source == "email")
        #expect(detail.summary.note == "Fwd: fuel")
        #expect(detail.summary.rejectionReason == "unreadable")
        #expect(detail.summary.imageCount == 1)
        #expect(detail.summary.id == UUID(uuidString: "9f1c0000-0000-4000-8000-000000000001"))
    }

    // MARK: - Presigned URLs (PR #45 / #46)

    @Test
    func decodesPresignedThumbnailFieldsAndKeepsThemOutOfTheStore() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()
        respond("""
        {"receipts":[{
          "id":"\(serverId.uuidString.lowercased())","status":"pending","source":"email",
          "ocr_status":"pending","image_count":1,
          "thumbnail_url":"https://r2.example.test/thumb.jpg?sig=abc",
          "first_image_path":"tenants/a/one.pdf",
          "first_image_mime_type":"application/pdf",
          "created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)

        await h.service.refresh(accountId: accountId)

        let row = try #require(try h.context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(row.firstImagePath == "tenants/a/one.pdf")
        #expect(row.firstImageMimeType == "application/pdf")
        #expect(h.service.thumbnailURLs[serverId]?.absoluteString
                == "https://r2.example.test/thumb.jpg?sig=abc")
    }

    /// A missing `thumbnail_url` is a normal state — older PDF receipts have no
    /// recorded page-1 thumbnail until their web card is viewed — so it must not
    /// fail the decode or the row.
    @Test
    func aRowWithNoPresignedFieldsStillDecodes() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()
        respond("""
        {"receipts":[{
          "id":"\(serverId.uuidString.lowercased())","status":"pending","source":"email",
          "ocr_status":"pending","image_count":1,
          "created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)

        await h.service.refresh(accountId: accountId)

        let row = try #require(try h.context.fetch(FetchDescriptor<LocalReceipt>()).first)
        #expect(row.firstImagePath == nil)
        #expect(row.firstImageMimeType == nil)
        #expect(h.service.thumbnailURLs[serverId] == nil, "no URL means the row falls back to its glyph")
    }

    /// Expiring URLs must not survive a refresh — a stale entry would render a
    /// dead link instead of falling back.
    @Test
    func refreshReplacesTheThumbnailURLMapRatherThanAccumulating() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let firstId = UUID()
        respond("""
        {"receipts":[{
          "id":"\(firstId.uuidString.lowercased())","status":"pending","source":"email",
          "ocr_status":"pending","image_count":1,
          "thumbnail_url":"https://r2.example.test/old.jpg",
          "created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22"
        }],"total":1,"limit":25,"offset":0}
        """)
        await h.service.refresh(accountId: accountId)
        #expect(h.service.thumbnailURLs[firstId] != nil)

        respond(#"{"receipts":[],"total":0,"limit":25,"offset":0}"#)
        await h.service.refresh(accountId: accountId)

        #expect(h.service.thumbnailURLs[firstId] == nil,
                "a receipt gone from the newest page must not keep a stale presigned URL")
    }

    /// Tapping through rows on iPad tears down the detail view mid-request. That
    /// is the user moving on, not a failure to report.
    @Test
    func aCancelledDetailFetchReportsCancelledRatherThanFailed() async throws {
        let h = try makePagingHarness()
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }

        let result = await h.service.fetchDetail(serverReceiptId: UUID(), accountId: UUID())

        guard case .cancelled = result else {
            Issue.record("expected .cancelled, got \(result)")
            return
        }
    }

    // MARK: - Request shape

    @Test
    func listSendsLimitAndOffsetAndOmitsStatusWhenNil() async throws {
        let api = makeAPI()
        let log = RequestLog()
        respond(#"{"receipts":[],"total":0,"limit":25,"offset":50}"#, log: log)

        _ = try await api.listReceipts(status: nil, limit: 25, offset: 50, accountId: UUID())

        let query = try #require(log.all.first?.query)
        #expect(query.contains("limit=25"))
        #expect(query.contains("offset=50"))
        #expect(!query.contains("status="), "an absent filter must not send an empty status")
    }

    @Test
    func listSendsStatusWhenProvided() async throws {
        let api = makeAPI()
        let log = RequestLog()
        respond(#"{"receipts":[],"total":0,"limit":25,"offset":0}"#, log: log)

        _ = try await api.listReceipts(status: "pending", limit: 25, offset: 0, accountId: UUID())

        #expect(try #require(log.all.first?.query).contains("status=pending"))
    }

    /// UUID.uuidString is uppercase, the DB stores lowercase, and SQLite compares
    /// case-sensitively — an uppercase path id is a guaranteed 404.
    @Test
    func detailPathUsesALowercaseId() async throws {
        let api = makeAPI()
        let log = RequestLog()
        respond("""
        {"id":"9f1c0000-0000-4000-8000-000000000001","status":"pending","source":"ios",
         "image_count":0,"created_at":"2026-07-27 14:03:22","updated_at":"2026-07-27 14:03:22",
         "images":[]}
        """, log: log)

        let id = UUID(uuidString: "9F1C0000-0000-4000-8000-000000000001")!
        _ = try await api.getReceipt(id: id, accountId: UUID())

        let path = try #require(log.all.first?.path)
        #expect(path == "/api/receipts/9f1c0000-0000-4000-8000-000000000001")
    }

    // MARK: - Paging harness

    /// Holds the container: `ModelContext` does not retain it, and a deallocated
    /// container traps inside SwiftData.
    private struct PagingHarness {
        let service: ReceiptListService
        let context: ModelContext
        let container: ModelContainer
        let monitor: NetworkMonitor
    }

    private func makePagingHarness(isConnected: Bool = true) throws -> PagingHarness {
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let monitor = NetworkMonitor()
        monitor.setConnectedForTesting(isConnected)
        let service = ReceiptListService(
            receiptAPI: makeAPI(),
            networkMonitor: monitor,
            modelContext: container.mainContext
        )
        return PagingHarness(
            service: service, context: container.mainContext,
            container: container, monitor: monitor
        )
    }

    /// Builds a page body of `count` rows dated one day apart descending, matching
    /// the server's newest-first ordering.
    private func pageBody(count: Int, total: Int, offset: Int, startDay: Int = 27) -> String {
        let rows = (0..<count).map { index -> String in
            let day = String(format: "%02d", max(1, startDay - index))
            return """
            {"id":"\(UUID().uuidString.lowercased())","status":"pending","source":"ios",
             "ocr_status":"pending","image_count":1,
             "created_at":"2026-07-\(day) 12:00:00","updated_at":"2026-07-\(day) 12:00:00"}
            """
        }
        return #"{"receipts":[\#(rows.joined(separator: ","))],"total":\#(total),"limit":25,"offset":\#(offset)}"#
    }

    // MARK: - Paging

    @Test
    func refreshMirrorsTheFirstPageAndRecordsTotal() async throws {
        let h = try makePagingHarness()
        respond(pageBody(count: 3, total: 137, offset: 0))

        await h.service.refresh(accountId: UUID())

        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 3)
        #expect(h.service.total == 137)
        #expect(h.service.hasMore == true)
        #expect(h.service.isLoadingPage == false)
        #expect(h.service.loadError == nil)
    }

    @Test
    func loadNextPageAdvancesTheOffset() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let log = RequestLog()
        respond(pageBody(count: 25, total: 60, offset: 0), log: log)
        await h.service.refresh(accountId: accountId)

        respond(pageBody(count: 25, total: 60, offset: 25, startDay: 2), log: log)
        await h.service.loadNextPage(accountId: accountId)

        let queries = log.all.compactMap(\.query)
        #expect(queries.contains { $0.contains("offset=0") })
        #expect(queries.contains { $0.contains("offset=25") })
        #expect(queries.allSatisfy { $0.contains("limit=25") })
    }

    @Test
    func hasMoreGoesFalseOnceTheTotalIsReached() async throws {
        let h = try makePagingHarness()
        respond(pageBody(count: 3, total: 3, offset: 0))

        await h.service.refresh(accountId: UUID())

        #expect(h.service.hasMore == false)
    }

    @Test
    func loadNextPageStopsOnAnEmptyPage() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        respond(pageBody(count: 2, total: 99, offset: 0))
        await h.service.refresh(accountId: accountId)

        respond(#"{"receipts":[],"total":99,"limit":25,"offset":25}"#)
        await h.service.loadNextPage(accountId: accountId)

        #expect(h.service.hasMore == false,
                "an empty page ends paging even when total disagrees")
    }

    @Test
    func refreshResetsPagingAfterAnAccountSwitch() async throws {
        let h = try makePagingHarness()
        let accountA = UUID()
        respond(pageBody(count: 25, total: 60, offset: 0))
        await h.service.refresh(accountId: accountA)
        respond(pageBody(count: 25, total: 60, offset: 25, startDay: 2))
        await h.service.loadNextPage(accountId: accountA)

        let accountB = UUID()
        let log = RequestLog()
        respond(pageBody(count: 1, total: 1, offset: 0), log: log)
        await h.service.refresh(accountId: accountB)

        #expect(try #require(log.all.first?.query).contains("offset=0"))
        #expect(h.service.total == 1)
    }

    /// Infinite scroll fires `loadNextPage` from a view body; without a guard a
    /// fast scroll issues the same page repeatedly.
    @Test
    func concurrentLoadNextPageCallsIssueOneRequest() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        respond(pageBody(count: 25, total: 99, offset: 0))
        await h.service.refresh(accountId: accountId)

        let log = RequestLog()
        respond(pageBody(count: 25, total: 99, offset: 25, startDay: 2), log: log)
        async let first: Set<UUID> = h.service.loadNextPage(accountId: accountId)
        async let second: Set<UUID> = h.service.loadNextPage(accountId: accountId)
        async let third: Set<UUID> = h.service.loadNextPage(accountId: accountId)
        _ = await (first, second, third)

        #expect(log.all.count == 1, "an in-flight page load must swallow duplicate triggers")
    }

    @Test
    func offlineRefreshMakesNoRequestAndKeepsTheMirror() async throws {
        let h = try makePagingHarness(isConnected: false)
        let accountId = UUID()
        ReceiptMirror(modelContext: h.context).upsert(
            [try JSONDecoder().decode(ReceiptSummaryDTO.self, from: Data("""
            {"id":"\(UUID().uuidString.lowercased())","status":"pending","source":"email",
             "ocr_status":"pending","image_count":1,
             "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00"}
            """.utf8))],
            accountId: accountId
        )
        let log = RequestLog()
        respond(pageBody(count: 1, total: 1, offset: 0), log: log)

        await h.service.refresh(accountId: accountId)

        #expect(log.all.isEmpty, "offline must not hit the network")
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1,
                "the cached history must still be there")
    }

    @Test
    func aFailedFetchSetsLoadErrorWithoutEmptyingTheMirror() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        respond(pageBody(count: 2, total: 2, offset: 0))
        await h.service.refresh(accountId: accountId)

        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await h.service.refresh(accountId: accountId)

        #expect(h.service.loadError != nil)
        #expect(h.service.isLoadingPage == false)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 2,
                "a failed request must never blank the list already on screen")
    }

    @Test
    func aSuccessfulRefreshClearsAPreviousError() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await h.service.refresh(accountId: accountId)
        #expect(h.service.loadError != nil)

        respond(pageBody(count: 1, total: 1, offset: 0))
        await h.service.refresh(accountId: accountId)

        #expect(h.service.loadError == nil)
    }

    // MARK: - Detail fetch

    @Test
    func fetchDetailMirrorsAReceiptThisDeviceNeverSaw() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()
        respond("""
        {"id":"\(serverId.uuidString.lowercased())","status":"rejected","source":"email",
         "ocr_status":"completed","rejection_reason":"unreadable","image_count":1,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 13:00:00",
         "images":[{"id":"b21d0000-0000-4000-8000-000000000003","file_path":"tenants/a/one.jpg",
          "file_name":"one.jpg","mime_type":"image/jpeg","sort_order":0}]}
        """)

        let result = await h.service.fetchDetail(serverReceiptId: serverId, accountId: accountId)

        guard case .ok(let row) = result else {
            Issue.record("expected .ok, got \(result)")
            return
        }
        #expect(row.serverReceiptId == serverId)
        #expect(row.isRemote == true)
        #expect(row.pages.count == 1)
        #expect(row.pages.first?.imageDownloaded == false)
    }

    /// A mirrored row is only a mirror — when the server says it is gone, it goes.
    @Test
    func detail404DeletesAMirroredRow() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()
        respond("""
        {"receipts":[{"id":"\(serverId.uuidString.lowercased())","status":"pending","source":"email",
         "ocr_status":"pending","image_count":1,
         "created_at":"2026-07-20 12:00:00","updated_at":"2026-07-20 12:00:00"}],
         "total":1,"limit":25,"offset":0}
        """)
        await h.service.refresh(accountId: accountId)
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)

        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{"error":"not found"}"#.data(using: .utf8)!)
        }
        let result = await h.service.fetchDetail(serverReceiptId: serverId, accountId: accountId)

        guard case .deleted = result else {
            Issue.record("expected .deleted, got \(result)")
            return
        }
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 0)
    }

    /// The local images are the only copy. A 404 marks the row removed; it must
    /// not destroy it.
    @Test
    func detail404OnALocalCaptureMarksItRemovedAndKeepsTheRow() async throws {
        let h = try makePagingHarness()
        let accountId = UUID()
        let serverId = UUID()

        let local = LocalReceipt(id: UUID(), accountId: accountId, syncStatus: .uploaded)
        local.serverReceiptId = serverId
        local.serverStatus = .pending
        local.isRemote = false
        h.context.insert(local)
        try h.context.save()

        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{"error":"not found"}"#.data(using: .utf8)!)
        }
        let result = await h.service.fetchDetail(serverReceiptId: serverId, accountId: accountId)

        guard case .removedFromServer = result else {
            Issue.record("expected .removedFromServer, got \(result)")
            return
        }
        #expect(try h.context.fetchCount(FetchDescriptor<LocalReceipt>()) == 1)
        #expect(local.serverStatus == .rejected)
        #expect(local.rejectionReason?.contains("Removed") == true)
        #expect(local.terminalStatusAt != nil)
    }
}

} // MockURLProtocolSuites
