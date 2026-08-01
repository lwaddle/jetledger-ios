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
    /// The server's terms-gate backstop: the user must accept the current
    /// Terms of Service before this endpoint will serve them. Structurally
    /// distinct from `.forbidden` because it is retryable-after-acceptance —
    /// treating it as a permission failure would park uploads permanently
    /// over a condition one tap resolves.
    case termsAcceptanceRequired
    case conflict
    case fileTooLarge
    /// The claim named an object that isn't in storage — the grant was reaped,
    /// or the PUT never landed. Recoverable only by uploading the bytes again.
    case uploadedImageMissing
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Authentication required. Please sign in again."
        case .forbidden: "You don't have permission to perform this action."
        case .termsAcceptanceRequired: "The updated Terms of Service must be accepted before continuing."
        case .conflict: "This receipt is being reviewed and can no longer be modified."
        case .fileTooLarge: "File is too large. Maximum size is 10MB for images and 20MB for PDFs."
        case .uploadedImageMissing: "The uploaded image expired before it was saved. Retrying the upload."
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
        case (.termsAcceptanceRequired, .termsAcceptanceRequired): true
        case (.conflict, .conflict): true
        case (.fileTooLarge, .fileTooLarge): true
        case (.uploadedImageMissing, .uploadedImageMissing): true
        case (.serverError(let a), .serverError(let b)): a == b
        default: false
        }
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}

/// The typed 403 body the terms-gate backstop returns on every non-allowlisted
/// authenticated endpoint while the user is behind on the Terms. Carries enough
/// to present the gate before any `terms` signal has been fetched — a
/// landing-time sync can hit this moments before the foreground accounts
/// refresh learns the same thing.
struct TermsRequiredPayload: Decodable {
    let error: String
    let termsVersion: String
    let termsUrl: String

    enum CodingKeys: String, CodingKey {
        case error
        case termsVersion = "terms_version"
        case termsUrl = "terms_url"
    }
}

// MARK: - API Client

class APIClient {
    let baseURL: URL
    var accountId: UUID?
    var onUnauthorized: (() -> Void)?
    /// Fired when any response is the terms-gate 403, so the gate can go up no
    /// matter which service's request tripped it — a queued upload can race the
    /// foreground accounts refresh and be the first to learn.
    var onTermsAcceptanceRequired: ((TermsRequiredPayload) -> Void)?
    /// Set by AuthService while a token rotation is in flight. Requests await it
    /// so they never fire carrying a token the server has already deleted.
    /// (The rotation call itself uses performRawRequest, which doesn't gate.)
    var refreshGate: Task<Void, Never>?

    private static let sessionTokenKey = "session_token"

    /// Endpoints that establish a session rather than use one. A stale Bearer
    /// token or X-Account-ID from a previous user must never ride along on
    /// these — the server doesn't need them and a leftover value from before
    /// sign-out ties the new login attempt to the old user's context.
    private static let preAuthPaths: Set<String> = [
        AppConstants.WebAPI.authLogin,
        AppConstants.WebAPI.authVerifyTOTP,
        AppConstants.WebAPI.authWebAuthnBegin,
        AppConstants.WebAPI.authWebAuthnFinish,
        AppConstants.WebAPI.authPasskeyBegin,
        AppConstants.WebAPI.authPasskeyFinish,
        AppConstants.WebAPI.authDeviceLogin,
    ]

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    private let session: URLSession

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(baseURL: URL, session: URLSession = APIClient.makeDefaultSession()) {
        self.baseURL = baseURL
        self.session = session
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

    func request<R: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        accountId: UUID? = nil
    ) async throws -> R {
        let (data, _) = try await performRequest(method, path, accountId: accountId)
        return try Self.decoder.decode(R.self, from: data)
    }

    func request<R: Decodable>(
        _ method: HTTPMethod,
        _ path: String,
        body: some Encodable,
        accountId: UUID? = nil
    ) async throws -> R {
        let bodyData = try Self.encoder.encode(body)
        let (data, _) = try await performRequest(method, path, bodyData: bodyData, accountId: accountId)
        return try Self.decoder.decode(R.self, from: data)
    }

    func requestVoid(_ method: HTTPMethod, _ path: String, accountId: UUID? = nil) async throws {
        _ = try await performRequest(method, path, accountId: accountId)
    }

    func requestVoid(
        _ method: HTTPMethod,
        _ path: String,
        body: some Encodable,
        accountId: UUID? = nil
    ) async throws {
        let bodyData = try Self.encoder.encode(body)
        _ = try await performRequest(method, path, bodyData: bodyData, accountId: accountId)
    }

    func get<R: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        accountId: UUID? = nil
    ) async throws -> R {
        let (data, _) = try await performRequest(.get, path, query: query, accountId: accountId)
        return try Self.decoder.decode(R.self, from: data)
    }

    /// Executes a request and returns raw data + HTTP status without translating
    /// non-2xx into `APIError` and without invoking `onUnauthorized`. For flows
    /// that interpret their own error responses (e.g. account deletion, where a
    /// 401 means "wrong password" not "session expired").
    func performRawRequest(
        _ method: HTTPMethod,
        _ path: String,
        bodyData: Data? = nil
    ) async throws -> (Data, Int) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        addHeaders(&request)
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(0)
        }
        return (data, http.statusCode)
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
            _ = try await session.data(for: request)
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
        query: [String: String] = [:],
        accountId: UUID? = nil
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

        // Hold new requests while a token rotation is mid-flight.
        if let gate = refreshGate { await gate.value }

        var attempts = 0
        while true {
            attempts += 1
            let tokenUsed = cachedToken

            var request = URLRequest(url: url)
            request.httpMethod = method.rawValue
            if !Self.preAuthPaths.contains(path) {
                addHeaders(&request, accountOverride: accountId)
            }
            if let bodyData {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = bodyData
            }

            let (data, response) = try await session.data(for: request)

            // A 401 on a token that has since been rotated isn't a dead session —
            // the request just raced the refresh. Retry once with the new token
            // before escalating to onUnauthorized.
            if let http = response as? HTTPURLResponse,
               http.statusCode == 401,
               attempts == 1 {
                if let gate = refreshGate { await gate.value }
                if tokenUsed != cachedToken { continue }
            }

            try validateResponse(response, data: data)
            return (data, response)
        }
    }

    /// `accountOverride` scopes a single request to a specific tenant — used by
    /// the upload queue, where a receipt's owning account may differ from the
    /// account currently selected in the UI.
    private func addHeaders(_ request: inout URLRequest, accountOverride: UUID? = nil) {
        if let token = cachedToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let effectiveAccount = accountOverride ?? accountId {
            request.setValue(effectiveAccount.uuidString, forHTTPHeaderField: "X-Account-ID")
        }
    }

    /// Non-nil only when a 403 body is the terms-gate backstop. `error` is an
    /// **exact-match contract** (like the drain middleware's `"maintenance"`)
    /// — deliberately not another substring match: a future error message that
    /// merely *mentions* terms must not flip the gate.
    static func termsRequiredPayload(from data: Data) -> TermsRequiredPayload? {
        guard let payload = try? decoder.decode(TermsRequiredPayload.self, from: data),
              payload.error == "terms_acceptance_required"
        else { return nil }
        return payload
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(0)
        }
        switch http.statusCode {
        case 200...299:
            return
        case 400:
            // POST /api/receipts reports two distinct, differently-recoverable
            // conditions as 400. Without reading the body both look transient
            // and the queue retries a claim that can never succeed.
            let message = (try? Self.decoder.decode(ServerErrorResponse.self, from: data))?.error ?? ""
            let normalized = message.lowercased()
            if normalized.contains("exceeds max size") {
                throw APIError.fileTooLarge
            }
            // Deliberately matched on the full phrase: a bare "not found" would
            // also swallow unrelated 400s (a stale trip reference, say) and
            // wrongly throw away good grants.
            if normalized.contains("uploaded image not found") {
                throw APIError.uploadedImageMissing
            }
            throw APIError.serverError(400)
        case 401:
            onUnauthorized?()
            let message = (try? Self.decoder.decode(ServerErrorResponse.self, from: data))?.error
            throw APIError.unauthorized(serverMessage: message)
        case 403:
            if let payload = Self.termsRequiredPayload(from: data) {
                onTermsAcceptanceRequired?(payload)
                throw APIError.termsAcceptanceRequired
            }
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
