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
            )
        )
    }

    // MARK: - Create Receipt

    func createReceipt(_ request: CreateReceiptRequest) async throws -> CreateReceiptResponse {
        try await apiClient.request(
            .post, AppConstants.WebAPI.receipts,
            body: request
        )
    }

    // MARK: - Delete Receipt

    func deleteReceipt(id: UUID) async throws {
        try await apiClient.requestVoid(
            .delete,
            "\(AppConstants.WebAPI.receipts)/\(id.uuidString)"
        )
    }

    // MARK: - Update Receipt

    func updateReceipt(id: UUID, note: String?, tripReferenceId: UUID?) async throws {
        try await apiClient.requestVoid(
            .patch,
            "\(AppConstants.WebAPI.receipts)/\(id.uuidString.lowercased())",
            body: UpdateReceiptRequest(
                note: note,
                tripReferenceId: tripReferenceId?.uuidString.lowercased()
            )
        )
    }

    // MARK: - Status Check

    func checkStatus(ids: [UUID]) async throws -> [ReceiptStatusResponse] {
        guard !ids.isEmpty else { return [] }
        // Swift's UUID.uuidString is uppercase; server stores lowercase (Go
        // uuid.New()) and SQLite `WHERE id = ?` is case-sensitive. Without this
        // the bulk lookup silently returns no matches and statuses never flip.
        let idsParam = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
        let wrapper: StatusCheckWrapper = try await apiClient.get(
            AppConstants.WebAPI.receiptStatus,
            query: ["ids": idsParam]
        )
        return wrapper.receipts
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

struct DeviceTokenRequest: Encodable {
    let token: String
    let platform: String
}

struct RegisterTokenResponse: Decodable {
    let registered: Bool
}
