//
//  ReceiptAPIService.swift
//  JetLedger
//

import Foundation

class ReceiptAPIService {
    private let baseURL: URL
    private let sessionProvider: () async -> String?

    init(baseURL: URL, sessionProvider: @escaping () async -> String?) {
        self.baseURL = baseURL
        self.sessionProvider = sessionProvider
    }

    // MARK: - Upload URL

    func getUploadURL(
        accountId: UUID,
        fileName: String,
        contentType: String,
        fileSize: Int
    ) async throws -> UploadURLResponse {
        let body = UploadURLRequest(
            accountId: accountId,
            fileName: fileName,
            contentType: contentType,
            fileSize: fileSize
        )
        return try await post(
            path: AppConstants.WebAPI.receiptUploadURL,
            body: body
        )
    }

    // MARK: - Create Receipt

    func createReceipt(_ request: CreateReceiptRequest) async throws -> CreateReceiptResponse {
        try await post(
            path: AppConstants.WebAPI.receipts,
            body: request
        )
    }

    // MARK: - Delete Receipt

    func deleteReceipt(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("\(AppConstants.WebAPI.receipts)/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try await authorizeRequest(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    // MARK: - Update Receipt

    func updateReceipt(
        id: UUID,
        note: String?,
        tripReferenceId: UUID?
    ) async throws {
        let url = baseURL.appendingPathComponent("\(AppConstants.WebAPI.receipts)/\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await authorizeRequest(&request)

        let body = UpdateReceiptRequest(note: note, tripReferenceId: tripReferenceId)
        request.httpBody = try JSONEncoder.apiEncoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    // MARK: - Status Check

    func checkStatus(ids: [UUID]) async throws -> [ReceiptStatusResponse] {
        guard !ids.isEmpty else { return [] }
        let idsParam = ids.map(\.uuidString).joined(separator: ",")
        var components = URLComponents(
            url: baseURL.appendingPathComponent(AppConstants.WebAPI.receiptStatus),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "ids", value: idsParam)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try await authorizeRequest(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        let wrapper = try JSONDecoder.apiDecoder.decode(StatusCheckWrapper.self, from: data)
        return wrapper.receipts
    }

    // MARK: - Helpers

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await authorizeRequest(&request)
        request.httpBody = try JSONEncoder.apiEncoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder.apiDecoder.decode(Response.self, from: data)
    }

    private func authorizeRequest(_ request: inout URLRequest) async throws {
        guard let token = await sessionProvider() else {
            throw APIError.unauthorized
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(0)
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 409:
            throw APIError.conflict
        case 413:
            throw APIError.fileTooLarge
        default:
            throw APIError.serverError(http.statusCode)
        }
    }
}

// MARK: - Error

enum APIError: Error, LocalizedError {
    case unauthorized
    case forbidden
    case conflict
    case fileTooLarge
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Authentication required. Please sign in again."
        case .forbidden: "You don't have permission to perform this action."
        case .conflict: "This receipt is being reviewed and can no longer be modified."
        case .fileTooLarge: "Image file is too large. Maximum size is 10MB."
        case .serverError(let code): "Server error (\(code)). Please try again later."
        }
    }
}

// MARK: - Request / Response DTOs

struct UploadURLRequest: Encodable {
    let accountId: UUID
    let fileName: String
    let contentType: String
    let fileSize: Int

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
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
    let tripReferenceId: UUID?
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

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileName = "file_name"
        case fileSize = "file_size"
        case sortOrder = "sort_order"
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
    let tripReferenceId: UUID?

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

// MARK: - JSON Coder Extensions

private extension JSONEncoder {
    static let apiEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()
}

private extension JSONDecoder {
    static let apiDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}
