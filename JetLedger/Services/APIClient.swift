//
//  APIClient.swift
//  JetLedger
//

import Foundation

// MARK: - HTTP Method

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - API Error

enum APIError: Error, LocalizedError, Equatable {
    case unauthorized(serverMessage: String? = nil)
    case forbidden
    case conflict
    case fileTooLarge
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Authentication required. Please sign in again."
        case .forbidden: "You don't have permission to perform this action."
        case .conflict: "This receipt is being reviewed and can no longer be modified."
        case .fileTooLarge: "File is too large. Maximum size is 10MB for images and 20MB for PDFs."
        case .serverError(let code): "Server error (\(code)). Please try again later."
        }
    }

    var serverMessage: String? {
        if case .unauthorized(let msg) = self { return msg }
        return nil
    }

    static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized): true
        case (.forbidden, .forbidden): true
        case (.conflict, .conflict): true
        case (.fileTooLarge, .fileTooLarge): true
        case (.serverError(let a), .serverError(let b)): a == b
        default: false
        }
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}

// MARK: - API Client

class APIClient {
    let baseURL: URL
    var accountId: UUID?
    var onUnauthorized: (() -> Void)?

    private static let sessionTokenKey = "session_token"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(baseURL: URL) {
        self.baseURL = baseURL
        cachedToken = Self.loadToken()
    }

    // MARK: - Token Management

    private(set) var cachedToken: String?

    var sessionToken: String? { cachedToken }

    func setSessionToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        KeychainHelper.save(key: Self.sessionTokenKey, data: data)
        cachedToken = token
    }

    func clearSessionToken() {
        KeychainHelper.delete(key: Self.sessionTokenKey)
        cachedToken = nil
    }

    private static func loadToken() -> String? {
        guard let data = KeychainHelper.read(key: sessionTokenKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Request Helpers

    func request<R: Decodable>(_ method: HTTPMethod, _ path: String) async throws -> R {
        let (data, _) = try await performRequest(method, path)
        return try Self.decoder.decode(R.self, from: data)
    }

    func request<R: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        body: some Encodable
    ) async throws -> R {
        let bodyData = try Self.encoder.encode(body)
        let (data, _) = try await performRequest(method, path, bodyData: bodyData)
        return try Self.decoder.decode(R.self, from: data)
    }

    func requestVoid(_ method: HTTPMethod, _ path: String) async throws {
        _ = try await performRequest(method, path)
    }

    func requestVoid(_ method: HTTPMethod, _ path: String, body: some Encodable) async throws {
        let bodyData = try Self.encoder.encode(body)
        _ = try await performRequest(method, path, bodyData: bodyData)
    }

    func get<R: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> R {
        let (data, _) = try await performRequest(.get, path, query: query)
        return try Self.decoder.decode(R.self, from: data)
    }

    // MARK: - Connectivity Probe

    /// Fast HEAD to the base URL used to confirm real reachability before entering
    /// flows that require network. Any HTTP response (even 4xx/5xx) counts as reachable
    /// — we only care about the round-trip, not the status. Returns false on URL-level
    /// failures (DNS, timeout, no route) — the cases NWPathMonitor can miss when a link
    /// exists but has no path to the server.
    func probeConnectivity(timeoutSeconds: Double = 2.0) async -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeoutSeconds
        do {
            _ = try await Self.session.data(for: request)
            return true
        } catch is URLError {
            return false
        } catch {
            return true
        }
    }

    // MARK: - Private

    private func performRequest(
        _ method: HTTPMethod,
        _ path: String,
        bodyData: Data? = nil,
        query: [String: String] = [:]
    ) async throws -> (Data, URLResponse) {
        let url: URL
        if query.isEmpty {
            url = baseURL.appendingPathComponent(path)
        } else {
            guard var components = URLComponents(
                url: baseURL.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            ) else {
                throw APIError.serverError(0)
            }
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let resolved = components.url else {
                throw APIError.serverError(0)
            }
            url = resolved
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        addHeaders(&request)
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, response) = try await Self.session.data(for: request)
        try validateResponse(response, data: data)
        return (data, response)
    }

    private func addHeaders(_ request: inout URLRequest) {
        if let token = cachedToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let accountId {
            request.setValue(accountId.uuidString, forHTTPHeaderField: "X-Account-ID")
        }
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(0)
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            onUnauthorized?()
            let message = (try? Self.decoder.decode(ServerErrorResponse.self, from: data))?.error
            throw APIError.unauthorized(serverMessage: message)
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
