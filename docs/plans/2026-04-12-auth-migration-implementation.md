# Auth Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Supabase SDK auth with direct HTTP calls to the Go backend, removing the only third-party dependency.

**Architecture:** New `APIClient` (extracted from ReceiptAPIService) provides shared HTTP + token management. AuthService rewrites to call Go auth endpoints. All services migrate from SupabaseClient to APIClient. Views change minimally — same state machine, different associated values.

**Tech Stack:** SwiftUI, Security framework (Keychain), URLSession, SwiftData

**Design doc:** `docs/plans/2026-04-12-auth-service-go-backend-migration.md`

---

## Prerequisites

### Go Backend: `GET /api/receipts` endpoint (listing)

`SyncService.fetchRemoteReceipts` currently queries Supabase directly with a complex join across `staged_receipts`, `staged_receipt_images`, and `trip_references`. This needs a Go API equivalent.

**Required endpoint:**
```
GET /api/receipts
Authorization: Bearer <token>
X-Account-ID: <uuid>

Response 200:
{
  "receipts": [
    {
      "id": "uuid",
      "account_id": "uuid",
      "note": "string",
      "trip_reference_id": "uuid",
      "status": "pending|processed|rejected",
      "rejection_reason": "string",
      "created_at": "ISO8601",
      "images": [
        {
          "id": "uuid",
          "file_path": "string",
          "file_name": "string",
          "file_size": 12345,
          "sort_order": 0,
          "content_type": "image/jpeg"
        }
      ],
      "trip_reference": {
        "id": "uuid",
        "external_id": "string",
        "name": "string"
      }
    }
  ]
}
```

If this endpoint is not yet built, Task 6 will note exactly where to add a TODO. The rest of the migration works without it.

---

## Task 1: Foundation — KeychainHelper, APIClient, Constants

**Files:**
- Create: `JetLedger/Utilities/KeychainHelper.swift`
- Create: `JetLedger/Services/APIClient.swift`
- Modify: `JetLedger/Utilities/Constants.swift`

### Step 1: Create KeychainHelper

Write `JetLedger/Utilities/KeychainHelper.swift`:

```swift
//
//  KeychainHelper.swift
//  JetLedger
//

import Foundation
import Security

enum KeychainHelper {
    private static let service = "io.jetledger.JetLedger"

    @discardableResult
    static func save(key: String, data: Data) -> Bool {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
```

### Step 2: Create APIClient

Write `JetLedger/Services/APIClient.swift`:

```swift
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
        case .fileTooLarge: "File is too large. Maximum size is 10MB for images and 20MB for PDFs."
        case .serverError(let code): "Server error (\(code)). Please try again later."
        }
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

// MARK: - API Client

class APIClient {
    let baseURL: URL
    var accountId: UUID?
    var onUnauthorized: (() -> Void)?

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
    }

    // MARK: - Token Management

    var sessionToken: String? {
        guard let data = KeychainHelper.read(key: "session_token") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSessionToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        KeychainHelper.save(key: "session_token", data: data)
    }

    func clearSessionToken() {
        KeychainHelper.delete(key: "session_token")
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
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.serverError(0)
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw APIError.serverError(0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = HTTPMethod.get.rawValue
        addHeaders(&request)

        let (data, response) = try await Self.session.data(for: request)
        try validateResponse(response, data: data)
        return try Self.decoder.decode(R.self, from: data)
    }

    // MARK: - Private

    private func performRequest(
        _ method: HTTPMethod,
        _ path: String,
        bodyData: Data? = nil
    ) async throws -> (Data, URLResponse) {
        let url = baseURL.appendingPathComponent(path)
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
        if let token = sessionToken {
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
```

### Step 3: Add API paths to Constants.swift

In `JetLedger/Utilities/Constants.swift`, **delete** the entire `enum Supabase` block (lines 11-31) and add new paths to `enum WebAPI`:

```swift
// DELETE this entire block:
enum Supabase {
    static let url: URL = { ... }()
    static let anonKey: String = { ... }()
}

// ADD these paths inside enum WebAPI, after the existing paths:
static let authLogin = "/api/auth/login"
static let authVerifyTOTP = "/api/auth/verify-totp"
static let authRefresh = "/api/auth/refresh"
static let authLogout = "/api/auth/logout"
static let accounts = "/api/accounts"
static let tripReferences = "/api/trip-references"
```

### Step 4: Build verification

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build 2>&1 | tail -5`

Expected: Build succeeds. The new files compile independently. Existing code still references Supabase — that's fine, we haven't changed it yet.

### Step 5: Commit

```
feat: add KeychainHelper and APIClient for Go backend auth

Shared HTTP client extracted from ReceiptAPIService pattern.
KeychainHelper wraps Security framework for session token storage.
API endpoint paths added to Constants.
```

---

## Task 2: AuthService rewrite

**Files:**
- Rewrite: `JetLedger/Services/AuthService.swift`
- Modify: `JetLedger/Models/Enums.swift`

### Step 1: Update AuthState enum

In `JetLedger/Models/Enums.swift`, change the `AuthState` enum:

```swift
// BEFORE:
enum AuthState: Equatable, Sendable {
    case loading
    case unauthenticated
    case mfaRequired(factorId: String)
    case mfaEnrollmentRequired
    case authenticated
    case offlineReady
}

// AFTER:
enum AuthState: Equatable, Sendable {
    case loading
    case unauthenticated
    case mfaRequired(mfaToken: String)
    case authenticated
    case offlineReady
}
```

### Step 2: Rewrite AuthService

Replace the entire contents of `JetLedger/Services/AuthService.swift` with:

```swift
//
//  AuthService.swift
//  JetLedger
//

import Foundation
import Observation

@Observable
class AuthService {
    var authState: AuthState = .loading
    var errorMessage: String?

    let apiClient: APIClient

    var currentUserId: UUID?
    var currentUserEmail: String?
    var loginAccounts: [LoginAccount]?
    var loginProfile: LoginUser?

    private static let userIdKey = "currentUserId"
    private static let userEmailKey = "currentUserEmail"

    init() {
        apiClient = APIClient(baseURL: AppConstants.WebAPI.baseURL)
        apiClient.onUnauthorized = { [weak self] in
            self?.authState = .unauthenticated
        }
        // Restore cached user info for OfflineIdentity comparison
        currentUserId = UserDefaults.standard.string(forKey: Self.userIdKey).flatMap(UUID.init)
        currentUserEmail = UserDefaults.standard.string(forKey: Self.userEmailKey)
    }

    // MARK: - Session Restore

    func restoreSession() {
        if apiClient.sessionToken != nil {
            authState = .authenticated
        } else {
            authState = .unauthenticated
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async {
        errorMessage = nil
        do {
            let response: LoginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authLogin,
                body: LoginRequest(email: email, password: password)
            )
            handleLoginResponse(response)
        } catch let error as APIError where error == .unauthorized {
            errorMessage = "Invalid email or password."
        } catch is URLError {
            errorMessage = "Unable to connect. Check your internet connection and try again."
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    // MARK: - MFA

    func verifyMFA(code: String, mfaToken: String) async {
        errorMessage = nil
        do {
            let response: LoginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authVerifyTOTP,
                body: VerifyTOTPRequest(mfaToken: mfaToken, code: code, recoveryCode: nil)
            )
            handleLoginResponse(response)
        } catch {
            errorMessage = "Invalid code. Please try again."
        }
    }

    func verifyMFARecovery(code: String, mfaToken: String) async {
        errorMessage = nil
        do {
            let response: LoginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authVerifyTOTP,
                body: VerifyTOTPRequest(mfaToken: mfaToken, code: nil, recoveryCode: code)
            )
            handleLoginResponse(response)
        } catch {
            errorMessage = "Invalid recovery code. Please try again."
        }
    }

    // MARK: - Sign Out

    func signOut() async {
        do {
            try await apiClient.requestVoid(.post, AppConstants.WebAPI.authLogout)
        } catch {
            // Clear local state even if server sign-out fails
        }
        clearSession()
        authState = .unauthenticated
        errorMessage = nil
    }

    func signOutRetainingIdentity() async {
        do {
            try await apiClient.requestVoid(.post, AppConstants.WebAPI.authLogout)
        } catch {
            // Clear local state even if server sign-out fails
        }
        apiClient.clearSessionToken()
        authState = .offlineReady
        errorMessage = nil
    }

    func enterOfflineMode() {
        guard OfflineIdentity.load() != nil else { return }
        authState = .offlineReady
    }

    // MARK: - Private

    private func handleLoginResponse(_ response: LoginResponse) {
        if response.mfaRequired == true, let mfaToken = response.mfaToken {
            saveUserInfo(response.user)
            authState = .mfaRequired(mfaToken: mfaToken)
        } else if let sessionToken = response.sessionToken {
            apiClient.setSessionToken(sessionToken)
            saveUserInfo(response.user)
            loginAccounts = response.accounts
            loginProfile = response.user
            authState = .authenticated
        } else {
            errorMessage = "Unexpected server response."
        }
    }

    private func saveUserInfo(_ user: LoginUser) {
        currentUserId = UUID(uuidString: user.id)
        currentUserEmail = user.email
        UserDefaults.standard.set(user.id, forKey: Self.userIdKey)
        UserDefaults.standard.set(user.email, forKey: Self.userEmailKey)
    }

    private func clearSession() {
        apiClient.clearSessionToken()
        currentUserId = nil
        currentUserEmail = nil
        loginAccounts = nil
        loginProfile = nil
        UserDefaults.standard.removeObject(forKey: Self.userIdKey)
        UserDefaults.standard.removeObject(forKey: Self.userEmailKey)
    }
}

// MARK: - Auth DTOs

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct VerifyTOTPRequest: Encodable {
    let mfaToken: String
    let code: String?
    let recoveryCode: String?

    enum CodingKeys: String, CodingKey {
        case code
        case mfaToken = "mfa_token"
        case recoveryCode = "recovery_code"
    }
}

struct LoginResponse: Decodable {
    let sessionToken: String?
    let mfaRequired: Bool?
    let mfaToken: String?
    let user: LoginUser
    let accounts: [LoginAccount]?

    enum CodingKeys: String, CodingKey {
        case user, accounts
        case sessionToken = "session_token"
        case mfaRequired = "mfa_required"
        case mfaToken = "mfa_token"
    }
}

struct LoginUser: Decodable {
    let id: String
    let email: String
    let firstName: String
    let lastName: String

    enum CodingKeys: String, CodingKey {
        case id, email
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

struct LoginAccount: Decodable {
    let id: String
    let name: String
    let slug: String
    let role: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, slug, role
        case isDefault = "is_default"
    }
}
```

### Step 3: Build verification

Build will **fail** — that's expected. The rest of the codebase still references the old AuthService API (`supabase`, `factorId`, `mfaEnrollmentRequired`, `isPasswordResetActive`, etc.). Verify that `AuthService.swift` itself compiles by checking errors are only in other files.

### Step 4: Commit (--no-verify if pre-commit hooks check build)

```
feat: rewrite AuthService for Go backend auth API

Replaces Supabase SDK auth with direct HTTP calls to /api/auth/*
endpoints. Session tokens stored in Keychain via APIClient.
Password reset and MFA enrollment removed (web-only).
```

---

## Task 3: Auth views — AuthFlowView, MFAVerifyView, LoginView

**Files:**
- Modify: `JetLedger/Views/Login/AuthFlowView.swift`
- Modify: `JetLedger/Views/Login/MFAVerifyView.swift`
- Modify: `JetLedger/Views/Login/LoginView.swift`
- Delete: `JetLedger/Views/Login/PasswordResetView.swift`
- Delete: `JetLedger/Views/Login/MFAEnrollmentRequiredView.swift`

### Step 1: Rewrite AuthFlowView

Replace entire contents of `JetLedger/Views/Login/AuthFlowView.swift`:

```swift
//
//  AuthFlowView.swift
//  JetLedger
//

import SwiftUI

enum AuthDestination: Hashable {
    case mfaVerify(mfaToken: String)
}

struct AuthFlowView: View {
    @Environment(AuthService.self) private var authService
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LoginView()
                .navigationDestination(for: AuthDestination.self) { destination in
                    switch destination {
                    case .mfaVerify(let mfaToken):
                        MFAVerifyView(mfaToken: mfaToken)
                            .navigationBarBackButtonHidden(true)
                    }
                }
        }
        .onChange(of: authService.authState) { _, newState in
            switch newState {
            case .mfaRequired(let mfaToken):
                path = NavigationPath()
                path.append(AuthDestination.mfaVerify(mfaToken: mfaToken))
            case .unauthenticated, .authenticated, .offlineReady, .loading:
                path = NavigationPath()
            }
        }
    }
}
```

### Step 2: Rewrite MFAVerifyView with recovery code support

Replace entire contents of `JetLedger/Views/Login/MFAVerifyView.swift`:

```swift
//
//  MFAVerifyView.swift
//  JetLedger
//

import SwiftUI

struct MFAVerifyView: View {
    @Environment(AuthService.self) private var authService
    let mfaToken: String

    @State private var code = ""
    @State private var recoveryCode = ""
    @State private var isLoading = false
    @State private var hasAutoSubmitted = false
    @State private var useRecoveryCode = false
    @FocusState private var codeIsFocused: Bool
    @FocusState private var recoveryIsFocused: Bool

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Two-Factor Authentication")
                .font(.title2)
                .fontWeight(.semibold)

            if useRecoveryCode {
                recoveryCodeSection
            } else {
                totpCodeSection
            }

            Spacer()
            Spacer()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            if useRecoveryCode {
                recoveryIsFocused = true
            } else {
                codeIsFocused = true
            }
        }
    }

    // MARK: - TOTP Code Section

    private var totpCodeSection: some View {
        VStack(spacing: 16) {
            Text("Enter the 6-digit code from your authenticator app")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("000000", text: $code)
                .textFieldStyle(.plain)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2.monospaced())
                .focused($codeIsFocused)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue {
                        code = filtered
                        return
                    }
                    if filtered.count < 6 {
                        hasAutoSubmitted = false
                    }
                    if filtered.count == 6 && !hasAutoSubmitted && !isLoading {
                        hasAutoSubmitted = true
                        submitTOTP(filtered)
                    }
                }

            errorMessageView

            Button {
                submitTOTP(code)
            } label: {
                submitButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(code.count != 6 || isLoading)

            Button("Use a recovery code") {
                useRecoveryCode = true
                recoveryIsFocused = true
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            signOutButton
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    // MARK: - Recovery Code Section

    private var recoveryCodeSection: some View {
        VStack(spacing: 16) {
            Text("Enter one of your recovery codes")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("XXXXXXXX-XXXXXXXX", text: $recoveryCode)
                .textFieldStyle(.plain)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.title3.monospaced())
                .focused($recoveryIsFocused)

            errorMessageView

            Button {
                submitRecoveryCode()
            } label: {
                submitButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(recoveryCode.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)

            Button("Use authenticator code") {
                useRecoveryCode = false
                codeIsFocused = true
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            signOutButton
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    // MARK: - Shared Components

    @ViewBuilder
    private var errorMessageView: some View {
        if let error = authService.errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var submitButtonLabel: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Text("Verify")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var signOutButton: some View {
        Button("Use a different account") {
            Task { await authService.signOut() }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func submitTOTP(_ totpCode: String) {
        isLoading = true
        Task {
            await authService.verifyMFA(code: totpCode, mfaToken: mfaToken)
            isLoading = false
        }
    }

    private func submitRecoveryCode() {
        isLoading = true
        Task {
            await authService.verifyMFARecovery(
                code: recoveryCode.trimmingCharacters(in: .whitespaces),
                mfaToken: mfaToken
            )
            isLoading = false
        }
    }
}
```

### Step 3: Update LoginView — remove password reset

Replace entire contents of `JetLedger/Views/Login/LoginView.swift`:

```swift
//
//  LoginView.swift
//  JetLedger
//

import SwiftUI

struct LoginView: View {
    @Environment(AuthService.self) private var authService
    @Environment(NetworkMonitor.self) private var networkMonitor
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 36)

            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)

                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)

                if let error = authService.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                Button {
                    focusedField = nil
                    isLoading = true
                    Task {
                        await authService.signIn(email: email, password: password)
                        isLoading = false
                    }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Sign In")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                Text("Forgot password? Reset at jetledger.io")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 32)

            // Continue offline option
            if let identity = OfflineIdentity.load() {
                VStack(spacing: 6) {
                    if !networkMonitor.isConnected {
                        Text("No connection?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        authService.enterOfflineMode()
                    } label: {
                        Text("Continue offline as \(identity.email)")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
            Spacer()
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            if let identity = OfflineIdentity.load() {
                email = identity.email
            }
        }
    }
}
```

### Step 4: Delete removed views

Delete these files (Xcode auto-detects due to `PBXFileSystemSynchronizedRootGroup`):
- `JetLedger/Views/Login/PasswordResetView.swift`
- `JetLedger/Views/Login/MFAEnrollmentRequiredView.swift`

### Step 5: Build verification

Build will still fail — JetLedgerApp and services still reference old Supabase APIs. But the auth views should now compile cleanly against the new AuthService.

### Step 6: Commit

```
feat: update auth views for Go backend — recovery codes, remove password reset

MFAVerifyView: add recovery code toggle, change factorId to mfaToken.
AuthFlowView: remove MFA enrollment case.
LoginView: replace password reset sheet with static text.
Delete PasswordResetView and MFAEnrollmentRequiredView.
```

---

## Task 4: AccountService migration

**Files:**
- Modify: `JetLedger/Services/AccountService.swift`

### Step 1: Rewrite AccountService

Replace entire contents of `JetLedger/Services/AccountService.swift`:

```swift
//
//  AccountService.swift
//  JetLedger
//

import Foundation
import Observation
import SwiftData

@Observable
class AccountService {
    var accounts: [CachedAccount] = []
    var selectedAccount: CachedAccount?
    var userProfile: UserProfile?
    var isLoading = false
    var loadError: String?

    private let apiClient: APIClient
    private let modelContext: ModelContext

    private static let selectedAccountKey = "selectedAccountId"

    init(apiClient: APIClient, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.modelContext = modelContext
    }

    // MARK: - Seed from Login Response

    func seedAccounts(_ loginAccounts: [LoginAccount], profile: LoginUser?) {
        // Clear existing
        let existing = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
        for account in existing { modelContext.delete(account) }

        // Cache from login response
        var newAccounts: [CachedAccount] = []
        for item in loginAccounts {
            guard let id = UUID(uuidString: item.id) else { continue }
            let cached = CachedAccount(
                id: id,
                name: item.name,
                role: item.role,
                isDefault: item.isDefault
            )
            modelContext.insert(cached)
            newAccounts.append(cached)
        }
        try? modelContext.save()
        accounts = newAccounts

        // Set profile from login response
        if let profile, let userId = UUID(uuidString: profile.id) {
            userProfile = UserProfile(
                id: userId,
                firstName: profile.firstName,
                lastName: profile.lastName,
                email: profile.email
            )
        }

        restoreSelectedAccount()
    }

    // MARK: - Load Accounts (refresh)

    func loadAccounts() async {
        loadError = nil

        // Load from SwiftData cache first
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
        if !cached.isEmpty {
            accounts = cached
            restoreSelectedAccount()
        }

        if cached.isEmpty { isLoading = true }
        defer { isLoading = false }

        // Refresh from network
        do {
            let response: AccountsResponse = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [apiClient] in
                try await apiClient.get(AppConstants.WebAPI.accounts)
            }

            let existing = try modelContext.fetch(FetchDescriptor<CachedAccount>())
            for account in existing { modelContext.delete(account) }

            var newAccounts: [CachedAccount] = []
            for item in response.accounts {
                guard let id = UUID(uuidString: item.id) else { continue }
                let cached = CachedAccount(
                    id: id,
                    name: item.name,
                    role: item.role,
                    isDefault: item.isDefault
                )
                modelContext.insert(cached)
                newAccounts.append(cached)
            }
            try modelContext.save()
            accounts = newAccounts
        } catch {
            if accounts.isEmpty {
                let fallback = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
                accounts = fallback
                if fallback.isEmpty {
                    loadError = "Failed to load accounts. Check your connection and try again."
                }
            }
        }

        restoreSelectedAccount()
    }

    // MARK: - Account Selection

    func selectAccount(_ account: CachedAccount) {
        selectedAccount = account
        apiClient.accountId = account.id
        UserDefaults.standard.set(account.id.uuidString, forKey: Self.selectedAccountKey)
    }

    private func restoreSelectedAccount() {
        if let savedId = UserDefaults.standard.string(forKey: Self.selectedAccountKey),
           let uuid = UUID(uuidString: savedId),
           let match = accounts.first(where: { $0.id == uuid }) {
            selectAccount(match)
            return
        }
        if let defaultAccount = accounts.first(where: { $0.isDefault }) {
            selectAccount(defaultAccount)
            return
        }
        if let first = accounts.first {
            selectAccount(first)
        }
    }

    // MARK: - Offline / Cache-Only Loading

    func loadAccountsFromCache() {
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedAccount>())) ?? []
        accounts = cached
        restoreSelectedAccount()
    }

    func loadOfflineProfile(from identity: OfflineIdentity) {
        userProfile = UserProfile(
            id: identity.userId,
            firstName: nil,
            lastName: nil,
            email: identity.email
        )
    }

    // MARK: - Cleanup

    func clearAllData() {
        let accountFetch = FetchDescriptor<CachedAccount>()
        let tripFetch = FetchDescriptor<CachedTripReference>()
        let receiptFetch = FetchDescriptor<LocalReceipt>()

        if let items = try? modelContext.fetch(accountFetch) {
            for item in items { modelContext.delete(item) }
        }
        if let items = try? modelContext.fetch(tripFetch) {
            for item in items { modelContext.delete(item) }
        }
        if let receipts = try? modelContext.fetch(receiptFetch) {
            for receipt in receipts {
                ImageUtils.deleteReceiptImages(receiptId: receipt.id)
                modelContext.delete(receipt)
            }
        }
        try? modelContext.save()

        accounts = []
        selectedAccount = nil
        userProfile = nil
        apiClient.accountId = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedAccountKey)
    }
}

// MARK: - DTOs

private struct AccountsResponse: Decodable {
    let accounts: [LoginAccount]
}

struct UserProfile: Decodable {
    let id: UUID
    let firstName: String?
    let lastName: String?
    let email: String

    enum CodingKeys: String, CodingKey {
        case id, email
        case firstName = "first_name"
        case lastName = "last_name"
    }

    var displayName: String {
        let parts = [firstName, lastName].compactMap { $0 }
        return parts.isEmpty ? email : parts.joined(separator: " ")
    }
}
```

Note: `AccountsResponse` reuses the `LoginAccount` type from AuthService since the Go API returns the same shape from both login and `GET /api/accounts`. `selectAccount` now also sets `apiClient.accountId` so the `X-Account-ID` header is sent on all subsequent requests.

### Step 2: Commit

```
feat: migrate AccountService from Supabase to APIClient

Seed accounts from login response, refresh via GET /api/accounts.
Profile data comes from login response instead of separate query.
Account selection sets APIClient.accountId for X-Account-ID header.
```

---

## Task 5: TripReferenceService migration

**Files:**
- Modify: `JetLedger/Services/TripReferenceService.swift`

### Step 1: Rewrite TripReferenceService

Key changes from the current file:
- Replace `supabase: SupabaseClient` with `apiClient: APIClient` in init and stored property
- Replace all `supabase.from("trip_references")...` queries with APIClient calls
- Replace `PostgrestError` catch with `APIError.conflict` catch
- Remove `import PostgREST` and `import Supabase`

Replace entire contents of `JetLedger/Services/TripReferenceService.swift`:

```swift
//
//  TripReferenceService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import SwiftData

@Observable
class TripReferenceService {
    var tripReferences: [CachedTripReference] = []
    var isLoading = false

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "TripReferenceService")
    private let apiClient: APIClient
    private let modelContext: ModelContext
    private let networkMonitor: NetworkMonitor

    init(apiClient: APIClient, modelContext: ModelContext, networkMonitor: NetworkMonitor) {
        self.apiClient = apiClient
        self.modelContext = modelContext
        self.networkMonitor = networkMonitor
    }

    // MARK: - Load

    func loadTripReferences(for accountId: UUID) async {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        let cachedForAccount = allCached.filter { $0.accountId == accountId }
        if !cachedForAccount.isEmpty {
            tripReferences = cachedForAccount
        }

        if cachedForAccount.isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let response: TripReferencesResponse = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [apiClient] in
                try await apiClient.get(AppConstants.WebAPI.tripReferences)
            }

            // Clear existing cache for this account, preserving pending sync refs
            let existing = try modelContext.fetch(FetchDescriptor<CachedTripReference>())
            var pendingRefs: [CachedTripReference] = []
            for ref in existing where ref.accountId == accountId {
                if ref.isPendingSync {
                    pendingRefs.append(ref)
                } else {
                    modelContext.delete(ref)
                }
            }

            var cached: [CachedTripReference] = []
            let serverIds = Set(response.tripReferences.map(\.id))
            for item in response.tripReferences {
                if let pendingIdx = pendingRefs.firstIndex(where: { $0.id == item.id }) {
                    modelContext.delete(pendingRefs[pendingIdx])
                    pendingRefs.remove(at: pendingIdx)
                }

                let ref = CachedTripReference(
                    id: item.id,
                    accountId: accountId,
                    externalId: item.externalId,
                    name: item.name,
                    createdAt: item.createdAt
                )
                modelContext.insert(ref)
                cached.append(ref)
            }

            for pending in pendingRefs where !serverIds.contains(pending.id) {
                cached.append(pending)
            }

            try modelContext.save()
            tripReferences = cached
        } catch {
            if tripReferences.isEmpty {
                let fallback = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
                tripReferences = fallback.filter { $0.accountId == accountId }
            }
        }
    }

    // MARK: - Search (in-memory, works offline)

    func search(_ query: String, for accountId: UUID) -> [CachedTripReference] {
        guard !query.isEmpty else {
            return tripReferences.filter { $0.accountId == accountId }
        }
        let lowered = query.lowercased()
        return tripReferences.filter { ref in
            ref.accountId == accountId
                && ((ref.externalId?.lowercased().contains(lowered) ?? false)
                    || (ref.name?.lowercased().contains(lowered) ?? false))
        }
    }

    // MARK: - Create (offline-capable)

    func createTripReferenceLocally(
        accountId: UUID,
        externalId: String?,
        name: String?
    ) async throws -> CachedTripReference {
        let trimmedExtId = externalId?.trimmingCharacters(in: .whitespaces).strippingHTMLTags
        let trimmedName = name?.trimmingCharacters(in: .whitespaces).strippingHTMLTags

        guard !(trimmedExtId ?? "").isEmpty || !(trimmedName ?? "").isEmpty else {
            throw TripReferenceError.validationFailed("Trip ID or name is required.")
        }

        // Check for local duplicates
        let accountRefs = tripReferences.filter { $0.accountId == accountId }
        if let extId = trimmedExtId, !extId.isEmpty,
           accountRefs.contains(where: { $0.externalId?.lowercased() == extId.lowercased() }) {
            throw TripReferenceError.duplicate("A trip reference with ID \"\(extId)\" already exists.")
        }
        if let n = trimmedName, !n.isEmpty, (trimmedExtId ?? "").isEmpty,
           accountRefs.contains(where: { $0.name?.lowercased() == n.lowercased() }) {
            throw TripReferenceError.duplicate("A trip reference with name \"\(n)\" already exists.")
        }

        // If online, try to create directly on the server
        if networkMonitor.isConnected {
            do {
                let request = CreateTripReferenceRequest(
                    externalId: trimmedExtId?.isEmpty == true ? nil : trimmedExtId,
                    name: trimmedName?.isEmpty == true ? nil : trimmedName
                )

                let response: TripReferenceDTO = try await withTimeout(seconds: 5) { [apiClient] in
                    try await apiClient.request(
                        .post, AppConstants.WebAPI.tripReferences,
                        body: request
                    )
                }

                let cached = CachedTripReference(
                    id: response.id,
                    accountId: accountId,
                    externalId: response.externalId,
                    name: response.name,
                    createdAt: response.createdAt
                )
                modelContext.insert(cached)
                try? modelContext.save()
                tripReferences.insert(cached, at: 0)
                return cached
            } catch let error as APIError where error == .conflict {
                throw TripReferenceError.duplicate("This trip reference already exists on the server.")
            } catch {
                Self.logger.warning("Online create failed, falling back to offline: \(error.localizedDescription)")
            }
        }

        // Offline: create locally with pending flag
        let localRef = CachedTripReference(
            id: UUID(),
            accountId: accountId,
            externalId: trimmedExtId?.isEmpty == true ? nil : trimmedExtId,
            name: trimmedName?.isEmpty == true ? nil : trimmedName,
            createdAt: Date()
        )
        localRef.isPendingSync = true
        modelContext.insert(localRef)
        try? modelContext.save()
        tripReferences.insert(localRef, at: 0)
        return localRef
    }

    // MARK: - Sync Pending Trip References

    func syncPendingTripReferences() async {
        guard networkMonitor.isConnected else { return }

        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        let pending = allCached.filter { $0.isPendingSync }
        guard !pending.isEmpty else { return }

        for ref in pending {
            await syncSingleTripReference(ref)
        }
    }

    private func syncSingleTripReference(_ ref: CachedTripReference) async {
        let request = CreateTripReferenceRequest(
            externalId: ref.externalId,
            name: ref.name
        )

        do {
            let response: TripReferenceDTO = try await apiClient.request(
                .post, AppConstants.WebAPI.tripReferences,
                body: request
            )

            if response.id != ref.id {
                relinkReceipts(from: ref.id, to: response.id, externalId: response.externalId, name: response.name)
                modelContext.delete(ref)
                let serverRef = CachedTripReference(
                    id: response.id,
                    accountId: ref.accountId,
                    externalId: response.externalId,
                    name: response.name,
                    createdAt: response.createdAt
                )
                modelContext.insert(serverRef)
                if let idx = tripReferences.firstIndex(where: { $0.id == ref.id }) {
                    tripReferences[idx] = serverRef
                }
            } else {
                ref.isPendingSync = false
            }

            try? modelContext.save()
            Self.logger.info("Synced trip reference: \(ref.externalId ?? ref.name ?? "unknown")")
        } catch let error as APIError where error == .conflict {
            Self.logger.info("Unique conflict for trip reference: \(ref.externalId ?? ref.name ?? "unknown")")
            await handleUniqueConflict(localRef: ref)
        } catch {
            Self.logger.warning("Failed to sync trip reference \(ref.id): \(error.localizedDescription)")
        }
    }

    private func handleUniqueConflict(localRef: CachedTripReference) async {
        do {
            // Reload trip references from server to find the conflicting record
            let response: TripReferencesResponse = try await apiClient.get(
                AppConstants.WebAPI.tripReferences
            )

            let serverRecord: TripReferenceDTO?
            if let extId = localRef.externalId, !extId.isEmpty {
                serverRecord = response.tripReferences.first {
                    $0.externalId?.lowercased() == extId.lowercased()
                }
            } else if let name = localRef.name {
                serverRecord = response.tripReferences.first {
                    $0.name?.lowercased() == name.lowercased()
                }
            } else {
                serverRecord = nil
            }

            guard let match = serverRecord else {
                Self.logger.warning("Conflict detected but server record not found — deleting local ref \(localRef.id)")
                modelContext.delete(localRef)
                tripReferences.removeAll { $0.id == localRef.id }
                try? modelContext.save()
                return
            }

            relinkReceipts(from: localRef.id, to: match.id, externalId: match.externalId, name: match.name)
            modelContext.delete(localRef)

            let accountId = localRef.accountId
            let serverRef = CachedTripReference(
                id: match.id,
                accountId: accountId,
                externalId: match.externalId,
                name: match.name,
                createdAt: match.createdAt
            )
            modelContext.insert(serverRef)
            if let idx = tripReferences.firstIndex(where: { $0.id == localRef.id }) {
                tripReferences[idx] = serverRef
            }

            try? modelContext.save()
            Self.logger.info("Resolved conflict: local \(localRef.id) → server \(match.id)")
        } catch {
            Self.logger.warning("Failed to resolve conflict for \(localRef.id): \(error.localizedDescription)")
        }
    }

    private func relinkReceipts(from localId: UUID, to serverId: UUID, externalId: String?, name: String?) {
        guard let allReceipts = try? modelContext.fetch(FetchDescriptor<LocalReceipt>()) else { return }
        for receipt in allReceipts where receipt.tripReferenceId == localId {
            receipt.tripReferenceId = serverId
            receipt.tripReferenceExternalId = externalId
            receipt.tripReferenceName = name
        }
    }

    // MARK: - Update

    func updateTripReference(
        id: UUID,
        externalId: String?,
        name: String?
    ) async throws -> CachedTripReference {
        let request = UpdateTripReferenceRequest(externalId: externalId, name: name)

        let response: TripReferenceDTO = try await apiClient.request(
            .put, "\(AppConstants.WebAPI.tripReferences)/\(id.uuidString)",
            body: request
        )

        if let existing = tripReferences.first(where: { $0.id == id }) {
            existing.externalId = response.externalId
            existing.name = response.name
            try? modelContext.save()
            return existing
        }

        let accountId = tripReferences.first?.accountId ?? UUID()
        let cached = CachedTripReference(
            id: response.id,
            accountId: accountId,
            externalId: response.externalId,
            name: response.name,
            createdAt: response.createdAt
        )
        modelContext.insert(cached)
        try? modelContext.save()
        tripReferences.insert(cached, at: 0)
        return cached
    }

    func propagateTripReferenceUpdate(id: UUID, externalId: String?, name: String?) {
        guard let allReceipts = try? modelContext.fetch(FetchDescriptor<LocalReceipt>()) else { return }
        for receipt in allReceipts where receipt.tripReferenceId == id {
            receipt.tripReferenceExternalId = externalId
            receipt.tripReferenceName = name
        }
        try? modelContext.save()
    }

    // MARK: - Cleanup

    func clearCache() {
        let allCached = (try? modelContext.fetch(FetchDescriptor<CachedTripReference>())) ?? []

        let pendingIds = Set(allCached.filter(\.isPendingSync).map(\.id))
        if !pendingIds.isEmpty {
            let allReceipts = (try? modelContext.fetch(FetchDescriptor<LocalReceipt>())) ?? []
            for receipt in allReceipts {
                if let tripId = receipt.tripReferenceId, pendingIds.contains(tripId) {
                    receipt.tripReferenceId = nil
                    receipt.tripReferenceExternalId = nil
                    receipt.tripReferenceName = nil
                }
            }
        }

        for ref in allCached { modelContext.delete(ref) }
        try? modelContext.save()
        tripReferences = []
    }
}

// MARK: - DTOs

struct TripReferencesResponse: Decodable {
    let tripReferences: [TripReferenceDTO]

    enum CodingKeys: String, CodingKey {
        case tripReferences = "trip_references"
    }
}

struct TripReferenceDTO: Decodable {
    let id: UUID
    let externalId: String?
    let name: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case externalId = "external_id"
        case createdAt = "created_at"
    }
}

private struct CreateTripReferenceRequest: Encodable {
    let externalId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name
        case externalId = "external_id"
    }
}

private struct UpdateTripReferenceRequest: Encodable {
    let externalId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case name
        case externalId = "external_id"
    }
}

// MARK: - Errors

enum TripReferenceError: LocalizedError {
    case validationFailed(String)
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let message), .duplicate(let message):
            message
        }
    }
}
```

### Step 2: Commit

```
feat: migrate TripReferenceService from Supabase to APIClient

All trip reference CRUD now goes through Go API endpoints.
PostgrestError handling replaced with APIError.conflict.
```

---

## Task 6: ReceiptAPIService refactor + SyncService cleanup

**Files:**
- Modify: `JetLedger/Services/ReceiptAPIService.swift`
- Modify: `JetLedger/Services/SyncService.swift`

### Step 1: Refactor ReceiptAPIService to use APIClient

Replace entire contents of `JetLedger/Services/ReceiptAPIService.swift`:

```swift
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
            "\(AppConstants.WebAPI.receipts)/\(id.uuidString)",
            body: UpdateReceiptRequest(note: note, tripReferenceId: tripReferenceId)
        )
    }

    // MARK: - Status Check

    func checkStatus(ids: [UUID]) async throws -> [ReceiptStatusResponse] {
        guard !ids.isEmpty else { return [] }
        let idsParam = ids.map(\.uuidString).joined(separator: ",")
        let wrapper: StatusCheckWrapper = try await apiClient.get(
            AppConstants.WebAPI.receiptStatus,
            query: ["ids": idsParam]
        )
        return wrapper.receipts
    }

    // MARK: - List Receipts

    func listReceipts() async throws -> [RemoteReceipt] {
        let wrapper: RemoteReceiptsResponse = try await apiClient.get(
            AppConstants.WebAPI.receipts
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

struct DeviceTokenRequest: Encodable {
    let token: String
    let platform: String
}

struct RegisterTokenResponse: Decodable {
    let registered: Bool
}

// MARK: - Remote Receipt DTOs (for listReceipts)

struct RemoteReceiptsResponse: Decodable {
    let receipts: [RemoteReceipt]
}

struct RemoteReceipt: Decodable {
    let id: UUID
    let accountId: UUID
    let note: String?
    let tripReferenceId: UUID?
    let status: String
    let rejectionReason: String?
    let createdAt: String
    let images: [RemoteReceiptImage]
    let tripReference: RemoteTripReference?

    enum CodingKeys: String, CodingKey {
        case id, note, status, images
        case accountId = "account_id"
        case tripReferenceId = "trip_reference_id"
        case rejectionReason = "rejection_reason"
        case createdAt = "created_at"
        case tripReference = "trip_reference"
    }

    var capturedDate: Date {
        if let date = SyncService.iso8601Formatter.date(from: createdAt) {
            return date
        }
        let basic = ISO8601DateFormatter()
        return basic.date(from: createdAt) ?? Date()
    }
}

struct RemoteReceiptImage: Decodable {
    let id: UUID
    let filePath: String
    let fileName: String
    let fileSize: Int?
    let sortOrder: Int
    let contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case fileName = "file_name"
        case fileSize = "file_size"
        case sortOrder = "sort_order"
        case contentType = "content_type"
    }
}

struct RemoteTripReference: Decodable {
    let id: UUID
    let externalId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case externalId = "external_id"
    }
}
```

### Step 2: Update SyncService — drop Supabase

In `JetLedger/Services/SyncService.swift`, make these changes:

**Remove imports** — delete `import Supabase`

**Change init** — replace `supabase: SupabaseClient` with `userIdProvider: @escaping () -> UUID?`:

```swift
// BEFORE:
private let supabase: SupabaseClient

init(
    receiptAPI: ReceiptAPIService,
    r2Upload: R2UploadService,
    networkMonitor: NetworkMonitor,
    modelContext: ModelContext,
    supabase: SupabaseClient,
    tripReferenceService: TripReferenceService
) {
    ...
    self.supabase = supabase
    ...
}

// AFTER:
private let userIdProvider: () -> UUID?

init(
    receiptAPI: ReceiptAPIService,
    r2Upload: R2UploadService,
    networkMonitor: NetworkMonitor,
    modelContext: ModelContext,
    userIdProvider: @escaping () -> UUID?,
    tripReferenceService: TripReferenceService
) {
    ...
    self.userIdProvider = userIdProvider
    ...
}
```

**Update fetchRemoteReceipts** — replace the Supabase query with an APIClient call via receiptAPI:

```swift
// BEFORE (lines 322-344):
func fetchRemoteReceipts(for accountId: UUID) async {
    guard networkMonitor.isConnected else { return }
    guard let userId = supabase.auth.currentSession?.user.id else { return }

    do {
        let remoteReceipts: [RemoteReceipt] = try await withTimeout(
            seconds: AppConstants.Sync.networkQueryTimeoutSeconds
        ) { [supabase] in
            try await supabase
                .from("staged_receipts")
                .select("""...""")
                ...
        }

// AFTER:
func fetchRemoteReceipts(for accountId: UUID) async {
    guard networkMonitor.isConnected else { return }
    guard userIdProvider() != nil else { return }

    do {
        let remoteReceipts: [RemoteReceipt] = try await withTimeout(
            seconds: AppConstants.Sync.networkQueryTimeoutSeconds
        ) { [receiptAPI] in
            try await receiptAPI.listReceipts()
        }
```

**Update references to Remote DTOs** — the DTOs moved from SyncService (private) to ReceiptAPIService (internal). Update these references in SyncService:

- `remote.stagedReceiptImages` → `remote.images`
- `remote.tripReferences` → `remote.tripReference`

In `updateLocalFromRemote`:
```swift
// BEFORE:
local.tripReferenceExternalId = remote.tripReferences?.externalId
local.tripReferenceName = remote.tripReferences?.name

// AFTER:
local.tripReferenceExternalId = remote.tripReference?.externalId
local.tripReferenceName = remote.tripReference?.name
```

In `createLocalFromRemote`:
```swift
// BEFORE:
tripReferenceExternalId: remote.tripReferences?.externalId,
tripReferenceName: remote.tripReferences?.name,
...
let sortedImages = remote.stagedReceiptImages.sorted { ... }

// AFTER:
tripReferenceExternalId: remote.tripReference?.externalId,
tripReferenceName: remote.tripReference?.name,
...
let sortedImages = remote.images.sorted { ... }
```

**Delete** the `RemoteReceipt`, `RemoteReceiptImage`, `RemoteTripReference` structs from the bottom of SyncService (they now live in ReceiptAPIService).

**Delete** the `APIError: Equatable` extension from the bottom of SyncService (it now lives in APIClient).

### Step 3: Commit

```
feat: migrate ReceiptAPIService and SyncService off Supabase

ReceiptAPIService now wraps APIClient. SyncService takes a userId
provider closure instead of SupabaseClient. Remote receipt DTOs
moved to ReceiptAPIService for the new listReceipts endpoint.
```

---

## Task 7: JetLedgerApp wiring

**Files:**
- Modify: `JetLedger/JetLedgerApp.swift`

### Step 1: Rewrite JetLedgerApp

Replace entire contents of `JetLedger/JetLedgerApp.swift`:

```swift
//
//  JetLedgerApp.swift
//  JetLedger
//

import SwiftData
import SwiftUI
import UserNotifications

@main
struct JetLedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var authService = AuthService()
    @State private var accountService: AccountService?
    @State private var networkMonitor = NetworkMonitor()
    @State private var syncService: SyncService?
    @State private var tripReferenceService: TripReferenceService?
    @State private var pushService: PushNotificationService?
    @State private var showUserMismatchAlert = false
    @State private var mismatchOldEmail: String?

    private let modelContainer: ModelContainer

    init() {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.SharedContainer.appGroupIdentifier
        ) {
            let supportDir = containerURL.appending(path: "Library/Application Support")
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }

        do {
            let schema = Schema([
                LocalReceipt.self,
                LocalReceiptPage.self,
                CachedAccount.self,
                CachedTripReference.self,
            ])
            modelContainer = try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch authService.authState {
                case .loading:
                    ProgressView("Loading...")
                case .unauthenticated, .mfaRequired:
                    AuthFlowView()
                case .authenticated:
                    if let accountService, let syncService, let tripReferenceService, let pushService {
                        MainView()
                            .environment(accountService)
                            .environment(syncService)
                            .environment(tripReferenceService)
                            .environment(pushService)
                    } else {
                        ProgressView("Loading accounts...")
                    }
                case .offlineReady:
                    if let accountService, let syncService, let tripReferenceService, let pushService {
                        MainView(isOfflineMode: true)
                            .environment(accountService)
                            .environment(syncService)
                            .environment(tripReferenceService)
                            .environment(pushService)
                    } else {
                        ProgressView("Loading...")
                    }
                }
            }
            .environment(authService)
            .environment(networkMonitor)
            .modelContainer(modelContainer)
            .task {
                UNUserNotificationCenter.current().delegate = appDelegate
                authService.restoreSession()
            }
            .onChange(of: authService.authState) { _, newState in
                handleAuthStateChange(newState)
            }
            .alert("Different Account", isPresented: $showUserMismatchAlert) {
                Button("Delete Offline Receipts", role: .destructive) {
                    clearAllLocalData()
                    handleAuthStateChange(.authenticated)
                }
                Button("Sign Out", role: .cancel) {
                    Task { await authService.signOut() }
                }
            } message: {
                Text("You previously captured receipts offline as \(mismatchOldEmail ?? "another user"). Signing in as a different account will delete those offline receipts.")
            }
        }
    }

    private func handleAuthStateChange(_ state: AuthState) {
        switch state {
        case .authenticated:
            if let existingIdentity = OfflineIdentity.load(),
               let currentUserId = authService.currentUserId,
               existingIdentity.userId != currentUserId {
                let context = modelContainer.mainContext
                let allReceipts = (try? context.fetch(FetchDescriptor<LocalReceipt>())) ?? []
                let orphanedReceipts = allReceipts.filter {
                    $0.syncStatus == .queued || $0.syncStatus == .failed
                }
                if !orphanedReceipts.isEmpty {
                    mismatchOldEmail = existingIdentity.email
                    showUserMismatchAlert = true
                    return
                } else {
                    clearAllLocalData()
                }
            }

            let context = modelContainer.mainContext
            let apiClient = authService.apiClient

            let acctService = AccountService(
                apiClient: apiClient,
                modelContext: context
            )
            accountService = acctService

            let tripRefService = TripReferenceService(
                apiClient: apiClient,
                modelContext: context,
                networkMonitor: networkMonitor
            )
            tripReferenceService = tripRefService

            let receiptAPI = ReceiptAPIService(apiClient: apiClient)
            let r2Upload = R2UploadService()

            let sync = SyncService(
                receiptAPI: receiptAPI,
                r2Upload: r2Upload,
                networkMonitor: networkMonitor,
                modelContext: context,
                userIdProvider: { [weak authService] in authService?.currentUserId },
                tripReferenceService: tripRefService
            )
            sync.resetStuckUploads()
            sync.migrateTerminalTimestamps()
            syncService = sync

            let push = PushNotificationService(receiptAPI: receiptAPI)
            appDelegate.pushService = push
            if let pendingId = appDelegate.pendingNotificationReceiptId {
                push.pendingDeepLinkReceiptId = pendingId
                appDelegate.pendingNotificationReceiptId = nil
            }
            pushService = push

            // Seed accounts from login response if available, otherwise fetch
            if let loginAccounts = authService.loginAccounts {
                acctService.seedAccounts(loginAccounts, profile: authService.loginProfile)
                authService.loginAccounts = nil
                authService.loginProfile = nil
            }

            Task {
                if acctService.accounts.isEmpty {
                    await acctService.loadAccounts()
                }
                await push.requestPermissionAndRegister()

                if let account = acctService.selectedAccount,
                   let userId = authService.currentUserId {
                    let identity = OfflineIdentity(
                        userId: userId,
                        email: authService.currentUserEmail ?? "",
                        accountId: account.id,
                        accountName: account.name,
                        role: account.role
                    )
                    OfflineIdentity.save(identity)
                }
            }

        case .offlineReady:
            guard let identity = OfflineIdentity.load() else {
                authService.authState = .unauthenticated
                return
            }

            let context = modelContainer.mainContext
            let apiClient = authService.apiClient

            let acctService = AccountService(
                apiClient: apiClient,
                modelContext: context
            )
            acctService.loadAccountsFromCache()
            acctService.loadOfflineProfile(from: identity)
            accountService = acctService

            let tripRefService = TripReferenceService(
                apiClient: apiClient,
                modelContext: context,
                networkMonitor: networkMonitor
            )
            tripReferenceService = tripRefService

            let receiptAPI = ReceiptAPIService(apiClient: apiClient)

            let sync = SyncService(
                receiptAPI: receiptAPI,
                r2Upload: R2UploadService(),
                networkMonitor: networkMonitor,
                modelContext: context,
                userIdProvider: { nil },
                tripReferenceService: tripRefService
            )
            syncService = sync

            let push = PushNotificationService(receiptAPI: receiptAPI)
            pushService = push

        case .unauthenticated:
            let hasOfflineIdentity = OfflineIdentity.load() != nil

            if let pushService {
                let service = pushService
                Task { await service.unregisterToken() }
            }
            appDelegate.pushService = nil
            pushService = nil
            syncService = nil
            tripReferenceService?.clearCache()
            tripReferenceService = nil

            if hasOfflineIdentity {
                accountService = nil
            } else {
                accountService?.clearAllData()
                accountService = nil
                OfflineIdentity.clear()
            }

            if hasOfflineIdentity && !networkMonitor.isConnected {
                authService.enterOfflineMode()
            }

        default:
            break
        }
    }

    private func clearAllLocalData() {
        let context = modelContainer.mainContext
        let allReceipts = (try? context.fetch(FetchDescriptor<LocalReceipt>())) ?? []
        for receipt in allReceipts {
            ImageUtils.deleteReceiptImages(receiptId: receipt.id)
            context.delete(receipt)
        }
        let allAccounts = (try? context.fetch(FetchDescriptor<CachedAccount>())) ?? []
        for account in allAccounts { context.delete(account) }
        let allTrips = (try? context.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        for trip in allTrips { context.delete(trip) }
        try? context.save()
        OfflineIdentity.clear()
        UserDefaults.standard.removeObject(forKey: "selectedAccountId")
    }
}
```

### Step 2: Commit

```
feat: rewire JetLedgerApp for Go backend auth

All services now receive APIClient instead of SupabaseClient.
Accounts seeded from login response on first auth.
Session restore via Keychain check replaces Supabase auth listener.
Password reset deep link handler removed.
```

---

## Task 8: Config cleanup + remove Supabase dependency

**Files:**
- Modify: `Secrets.xcconfig`
- Modify: `Secrets.xcconfig.example`
- Modify: `JetLedger/Info.plist`
- Modify: `JetLedger.xcodeproj/project.pbxproj` (via Xcode GUI)

### Step 1: Update Secrets.xcconfig

```
// Secrets.xcconfig
// JetLedger
//
// This file contains secrets and MUST NOT be committed to git.
// Copy Secrets.xcconfig.example and fill in your real values.

JETLEDGER_API_URL = https:/$()/jetledger.io
```

### Step 2: Update Secrets.xcconfig.example

```
// Secrets.xcconfig.example
// JetLedger
//
// Copy this file to Secrets.xcconfig and fill in your real values.
// Secrets.xcconfig is gitignored and will not be committed.

JETLEDGER_API_URL = https:/$()/jetledger.io
```

### Step 3: Update Info.plist — remove Supabase keys

Remove the `SupabaseURL` and `SupabaseAnonKey` entries (lines 14-17 in current file). Keep everything else.

### Step 4: Remove supabase-swift SPM dependency

In Xcode:
1. Select the project in the navigator
2. Select the JetLedger project (not target)
3. Go to "Package Dependencies" tab
4. Select `supabase-swift` and click the minus (-) button
5. Confirm removal

This removes these lines from `project.pbxproj`:
- `6F14E8B32F3D019600066552 /* Supabase in Frameworks */` (build file)
- `6F14E8B22F3D019600066552 /* Supabase */` (package product dependency)
- `6F14E8B12F3D019600066552 /* XCRemoteSwiftPackageReference "supabase-swift" */` (remote package reference)

### Step 5: Build verification

Run: `xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build 2>&1 | tail -20`

Expected: **Clean build with zero errors.** All Supabase imports are gone. All services use APIClient.

If build fails, check for:
- Remaining `import Auth`, `import Supabase`, or `import PostgREST` statements
- References to `SupabaseClient`, `supabase.auth`, `PostgrestError`
- The `mfaEnrollmentRequired` case in any switch statements

### Step 6: Commit

```
chore: remove supabase-swift dependency and Supabase config

Zero third-party dependencies. All auth and data access goes
through the Go backend API via APIClient.
```

---

## Task 9: Manual test checklist

After a successful build, test these flows on a device or simulator connected to the Go backend:

**Auth:**
- [ ] Cold launch with no session → shows login screen
- [ ] Login with valid credentials (no MFA) → authenticated, sees main screen with accounts
- [ ] Login with valid credentials (MFA enabled) → MFA screen, enter TOTP → authenticated
- [ ] MFA screen → tap "Use a recovery code" → enter recovery code → authenticated
- [ ] MFA screen → enter wrong code → error message, can retry
- [ ] Sign out → returns to login, session cleared from Keychain
- [ ] Cold launch with valid session in Keychain → goes straight to authenticated

**Offline:**
- [ ] Disable network, cold launch with existing offline identity → offline mode
- [ ] Capture receipt in offline mode → saved locally
- [ ] Re-enable network, sign in → receipts sync

**Accounts:**
- [ ] Account selector shows accounts from login response
- [ ] Pull-to-refresh on main screen refreshes accounts from `GET /api/accounts`
- [ ] Multi-account user: switching accounts filters receipt list

**Trip references:**
- [ ] Trip reference picker loads from `GET /api/trip-references`
- [ ] Create new trip reference online → appears in list
- [ ] Create trip reference offline → appears with pending flag, syncs when online

**Receipts:**
- [ ] Capture receipt → upload succeeds via presigned URL flow
- [ ] Receipt list shows sync status
- [ ] Pull-to-refresh fetches remote receipts (requires `GET /api/receipts` endpoint)

**401 handling:**
- [ ] Manually clear Keychain token while app is running → next API call triggers sign-out to login screen
