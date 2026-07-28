//
//  ReceiptAPIService.swift
//  JetLedger
//

import Foundation

class ReceiptAPIService {
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Download URL

    func getDownloadURL(filePath: String) async throws -> DownloadURLResponse {
        try await apiClient.request(
            .post, AppConstants.WebAPI.receiptDownloadURL,
            body: DownloadURLRequest(filePath: filePath)
        )
    }

    // MARK: - Upload URL

    func getUploadURL(
        accountId: UUID,
        stagedReceiptId: UUID,
        fileName: String,
        contentType: String,
        fileSize: Int
    ) async throws -> UploadURLResponse {
        try await apiClient.request(
            .post, AppConstants.WebAPI.receiptUploadURL,
            body: UploadURLRequest(
                accountId: accountId,
                stagedReceiptId: stagedReceiptId,
                fileName: fileName,
                contentType: contentType,
                fileSize: fileSize
            ),
            accountId: accountId
        )
    }

    // MARK: - Create Receipt

    func createReceipt(
        _ request: CreateReceiptRequest,
        accountId: UUID
    ) async throws -> CreateReceiptResponse {
        try await apiClient.request(
            .post, AppConstants.WebAPI.receipts,
            body: request,
            accountId: accountId
        )
    }

    // MARK: - Delete Receipt

    func deleteReceipt(id: UUID, accountId: UUID) async throws {
        try await apiClient.requestVoid(
            .delete,
            "\(AppConstants.WebAPI.receipts)/\(id.uuidString.lowercased())",
            accountId: accountId
        )
    }

    // MARK: - Update Receipt

    func updateReceipt(
        id: UUID,
        note: String?,
        tripReferenceId: UUID?,
        accountId: UUID
    ) async throws {
        try await apiClient.requestVoid(
            .patch,
            "\(AppConstants.WebAPI.receipts)/\(id.uuidString.lowercased())",
            body: UpdateReceiptRequest(
                note: note,
                tripReferenceId: tripReferenceId?.uuidString.lowercased()
            ),
            accountId: accountId
        )
    }

    // MARK: - Status Check

    func checkStatus(ids: [UUID], accountId: UUID) async throws -> [ReceiptStatusResponse] {
        guard !ids.isEmpty else { return [] }
        // Swift's UUID.uuidString is uppercase; server stores lowercase (Go
        // uuid.New()) and SQLite `WHERE id = ?` is case-sensitive. Without this
        // the bulk lookup silently returns no matches and statuses never flip.
        let idsParam = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
        let wrapper: StatusCheckWrapper = try await apiClient.get(
            AppConstants.WebAPI.receiptStatus,
            query: ["ids": idsParam],
            accountId: accountId
        )
        return wrapper.receipts
    }

    // MARK: - List / Detail

    /// The authenticated user's own staged receipts, newest first. Tenant scope
    /// comes from `X-Account-ID`.
    func listReceipts(
        status: String?,
        limit: Int,
        offset: Int,
        accountId: UUID
    ) async throws -> ReceiptListResponse {
        var query = ["limit": String(limit), "offset": String(offset)]
        if let status { query["status"] = status }
        return try await apiClient.get(
            AppConstants.WebAPI.receipts,
            query: query,
            accountId: accountId
        )
    }

    /// 404 here means "not yours or not there" — the endpoint deliberately does
    /// not distinguish the two.
    func getReceipt(id: UUID, accountId: UUID) async throws -> ReceiptDetailDTO {
        try await apiClient.request(
            .get,
            "\(AppConstants.WebAPI.receipts)/\(id.uuidString.lowercased())",
            accountId: accountId
        )
    }

    // MARK: - Device Tokens

    func registerDeviceToken(_ token: String) async throws {
        let _: RegisterTokenResponse = try await apiClient.request(
            .post, AppConstants.WebAPI.deviceTokens,
            body: DeviceTokenRequest(token: token, platform: "ios")
        )
    }

    func unregisterDeviceToken(_ token: String) async throws {
        try await apiClient.requestVoid(
            .delete, AppConstants.WebAPI.deviceTokens,
            body: DeviceTokenRequest(token: token, platform: "ios")
        )
    }
}

// MARK: - Request / Response DTOs

struct DownloadURLRequest: Encodable {
    let filePath: String
    enum CodingKeys: String, CodingKey { case filePath = "file_path" }
}

struct DownloadURLResponse: Decodable {
    let downloadUrl: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case downloadUrl = "download_url"
        case expiresIn = "expires_in"
    }
}

struct UploadURLRequest: Encodable {
    let accountId: UUID
    let stagedReceiptId: UUID
    let fileName: String
    let contentType: String
    let fileSize: Int
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case stagedReceiptId = "staged_receipt_id"
        case fileName = "file_name"
        case contentType = "content_type"
        case fileSize = "file_size"
    }
}

struct UploadURLResponse: Decodable {
    let uploadUrl: String
    let filePath: String
    enum CodingKeys: String, CodingKey {
        case uploadUrl = "upload_url"
        case filePath = "file_path"
    }
}

struct CreateReceiptRequest: Encodable {
    let accountId: UUID
    let note: String?
    // Sent as lowercase String to match server storage — SQLite FK comparison is
    // case-sensitive; Swift's UUID.uuidString is uppercase; Go's uuid.New() produces
    // lowercase. See ReceiptAPIService.updateReceipt for the symmetric normalization.
    let tripReferenceId: String?
    let images: [CreateReceiptImageRequest]
    enum CodingKeys: String, CodingKey {
        case note, images
        case accountId = "account_id"
        case tripReferenceId = "trip_reference_id"
    }
}

struct CreateReceiptImageRequest: Encodable {
    let filePath: String
    let fileName: String
    let fileSize: Int
    let sortOrder: Int
    let contentType: String
    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileName = "file_name"
        case fileSize = "file_size"
        case sortOrder = "sort_order"
        case contentType = "content_type"
    }
}

struct CreateReceiptResponse: Decodable {
    let id: UUID
    let status: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, status
        case createdAt = "created_at"
    }
}

struct UpdateReceiptRequest: Encodable {
    let note: String?
    // See CreateReceiptRequest.tripReferenceId comment.
    let tripReferenceId: String?
    enum CodingKeys: String, CodingKey {
        case note
        case tripReferenceId = "trip_reference_id"
    }
}

struct ReceiptStatusResponse: Decodable {
    let id: UUID
    let status: String
    let expenseId: UUID?
    let rejectionReason: String?
    enum CodingKeys: String, CodingKey {
        case id, status
        case expenseId = "expense_id"
        case rejectionReason = "rejection_reason"
    }
}

private struct StatusCheckWrapper: Decodable {
    let receipts: [ReceiptStatusResponse]
}

// MARK: - List / Detail DTOs

/// One row of `GET /api/receipts`.
///
/// `note`, `tripReferenceId`, `rejectionReason` and `expenseId` are `omitempty`
/// server-side — the key is *absent*, not null — so every one of them must be
/// optional or the whole page fails to decode.
///
/// `createdAt` / `updatedAt` stay `String` and are parsed with
/// `ServerDateFormatter`; they are SQLite `datetime('now')` output, which no
/// JSONDecoder date strategy handles.
struct ReceiptSummaryDTO: Decodable {
    let id: UUID
    let status: String
    let source: String
    let note: String?
    let tripReferenceId: UUID?
    let ocrStatus: String?
    let rejectionReason: String?
    let expenseId: UUID?
    let imageCount: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, status, source, note
        case tripReferenceId = "trip_reference_id"
        case ocrStatus = "ocr_status"
        case rejectionReason = "rejection_reason"
        case expenseId = "expense_id"
        case imageCount = "image_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        source = try container.decode(String.self, forKey: .source)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        tripReferenceId = Self.optionalUUID(container, .tripReferenceId)
        ocrStatus = try container.decodeIfPresent(String.self, forKey: .ocrStatus)
        rejectionReason = try container.decodeIfPresent(String.self, forKey: .rejectionReason)
        expenseId = Self.optionalUUID(container, .expenseId)
        // Go's `omitempty` drops an int that is zero, so a receipt with no images
        // may arrive with the key missing. Defaulting beats failing the page.
        imageCount = (try? container.decodeIfPresent(Int.self, forKey: .imageCount)) ?? 0
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }

    /// The contract calls these `omitempty`, but its own example payload sends
    /// `"expense_id": ""` — so the key can be absent *or* present-and-empty, and
    /// an empty string is not a UUID. Decoding it strictly throws, and one bad
    /// field would fail the entire page rather than one receipt's expense link.
    /// An unparseable value is treated as absent for the same reason.
    private static func optionalUUID(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> UUID? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key),
              !raw.isEmpty
        else { return nil }
        return UUID(uuidString: raw)
    }
}

struct ReceiptImageDTO: Decodable {
    let id: UUID
    let filePath: String
    let fileName: String
    let mimeType: String
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case sortOrder = "sort_order"
    }
}

/// `GET /api/receipts/{id}` — a list row plus its images.
///
/// The detail payload is flat: the row's fields and `images` sit at the same
/// level. `ReceiptSummaryDTO` is decoded from that same container rather than
/// its eleven fields being restated here, so the two responses cannot drift and
/// the mirror applies both through one code path.
struct ReceiptDetailDTO: Decodable {
    let summary: ReceiptSummaryDTO
    let images: [ReceiptImageDTO]

    enum CodingKeys: String, CodingKey {
        case images
    }

    init(from decoder: any Decoder) throws {
        summary = try ReceiptSummaryDTO(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        images = try container.decode([ReceiptImageDTO].self, forKey: .images)
    }
}

struct ReceiptListResponse: Decodable {
    let receipts: [ReceiptSummaryDTO]
    /// Count matching the filter, not the page size — this is what drives paging.
    let total: Int
    let limit: Int
    let offset: Int
}

struct DeviceTokenRequest: Encodable {
    let token: String
    let platform: String
}

struct RegisterTokenResponse: Decodable {
    let registered: Bool
}
