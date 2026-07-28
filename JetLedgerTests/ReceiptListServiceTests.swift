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
}

} // MockURLProtocolSuites
