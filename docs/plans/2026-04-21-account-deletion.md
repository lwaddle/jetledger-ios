# Native In-App Account Deletion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a native in-app "Delete Account" flow to satisfy Apple App Store Review Guideline 5.1.1(v), mirroring the web app's UX (password + email confirmation, 30-day grace period) against the existing `POST /api/user/delete-account` endpoint.

**Architecture:** A new `DeleteAccountView` sheet renders a three-state UI (form → submitting → success). Two new methods on `AuthService` — `deleteAccount(password:confirmEmail:)` issues the server call, `performFullAccountWipe()` handles the destructive local cleanup after the user confirms the scheduled deletion. A new `APIClient.performRawRequest` helper lets the delete-account flow handle its own 401 (wrong password) without triggering the global biometric re-auth callback.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, URLSession, Swift Testing framework.

**Design reference:** `docs/plans/2026-04-21-account-deletion-design.md`.

---

## Server contract (verified)

- **Endpoint:** `POST /api/user/delete-account`
- **Auth:** Bearer token (existing `APIClient` auth header works)
- **Request body:** `{"password": string, "confirm_email": string}` — note field name is `confirm_email`
- **Success (200):** `{"message": string, "deletion_scheduled_for": string}` — RFC3339 date
- **Errors:**
  - 400 — invalid body / missing fields
  - 401 — "incorrect password"
  - 409 — "account is already scheduled for deletion" OR **last-admin** message (`you are the only admin on "…" — transfer admin role or remove other members…`)
  - 422 — "email does not match"
  - 500 — internal error

Source: `api/auth.go:535` (`DeleteAccount`), `services/account_deletion.go` (`RequestAccountDeletion`, `LastAdminError`).

---

## Task 1: Refactor `APIClient` to accept an injectable `URLSession`

**Why:** Tests need to inject a `URLSession` configured with `MockURLProtocol` to stub HTTP responses for `deleteAccount` error-path tests. Minimal, backward-compatible change.

**Files:**
- Modify: `JetLedger/Services/APIClient.swift`

**Step 1: Read the current `APIClient` init and session configuration (lines 60–87).**

The static `private static let session` is used directly by `performRequest` and `probeConnectivity`. To make it injectable:

**Step 2: Replace the static session with an instance property, keeping the default factory.**

In `APIClient`:

```swift
let baseURL: URL
var accountId: UUID?
var onUnauthorized: (() -> Void)?

private static let sessionTokenKey = "session_token"

private static func makeDefaultSession() -> URLSession {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 120
    return URLSession(configuration: config)
}

private let session: URLSession

// ... encoder/decoder unchanged ...

init(baseURL: URL, session: URLSession = APIClient.makeDefaultSession()) {
    self.baseURL = baseURL
    self.session = session
    cachedToken = Self.loadToken()
}
```

Update `performRequest` to use `self.session` instead of `Self.session` (line 196). Update `probeConnectivity` the same way (line 154).

**Step 3: Build to verify nothing breaks.**

```bash
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```
Expected: BUILD SUCCEEDED.

**Step 4: Run existing tests — especially `TripReferenceServiceTests` which constructs `APIClient(baseURL:)`.**

```bash
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet -only-testing:JetLedgerTests
```
Expected: all tests pass (the default-parameter init preserves the existing call site).

**Step 5: Commit.**

```bash
git add JetLedger/Services/APIClient.swift
git commit -m "refactor: make APIClient URLSession injectable for tests"
```

---

## Task 2: Add `APIClient.performRawRequest(method:path:body:)` helper

**Why:** The delete-account flow returns 401 for "incorrect password". The existing `performRequest` invokes `onUnauthorized?()` on any 401, which triggers the app's global biometric re-auth path. For this flow we want to see the raw 401 and map it to a user-visible "incorrect password" error without a Face ID prompt.

**Files:**
- Modify: `JetLedger/Services/APIClient.swift`

**Step 1: Add a `MockURLProtocol` test helper.**

Create `JetLedgerTests/Helpers/MockURLProtocol.swift`:

```swift
import Foundation

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

**Step 2: Write a failing test for `performRawRequest`.**

Append to `JetLedgerTests/JetLedgerTests.swift`:

```swift
@MainActor
struct APIClientRawRequestTests {
    @Test
    func performRawRequestReturns401WithoutInvokingOnUnauthorized() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = #"{"error":"incorrect password"}"#.data(using: .utf8)!
            return (response, body)
        }

        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: MockURLProtocol.makeSession()
        )
        var unauthorizedCalled = false
        client.onUnauthorized = { unauthorizedCalled = true }

        let (data, status) = try await client.performRawRequest(
            .post, "/api/user/delete-account",
            bodyData: Data("{}".utf8)
        )

        #expect(status == 401)
        #expect(String(data: data, encoding: .utf8) == #"{"error":"incorrect password"}"#)
        #expect(unauthorizedCalled == false)
    }
}
```

**Step 3: Run the test — expect FAIL (method doesn't exist).**

```bash
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet -only-testing:JetLedgerTests/APIClientRawRequestTests
```
Expected: compile error — `performRawRequest` is not a member of APIClient.

**Step 4: Implement `performRawRequest`.**

In `APIClient.swift`, add to the `MARK: - Request Helpers` section:

```swift
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
```

Note: `addHeaders` is `private` in APIClient — this new method is a member function so it can call it directly.

**Step 5: Run the test — expect PASS.**

```bash
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet -only-testing:JetLedgerTests/APIClientRawRequestTests
```
Expected: all tests pass.

**Step 6: Commit.**

```bash
git add JetLedger/Services/APIClient.swift JetLedgerTests/
git commit -m "feat: add APIClient.performRawRequest for flow-scoped error handling"
```

---

## Task 3: Add `DeleteAccountError` and `AuthService.deleteAccount`

**Files:**
- Modify: `JetLedger/Services/AuthService.swift`
- Modify: `JetLedger/Utilities/Constants.swift` (add endpoint path)
- Test: `JetLedgerTests/JetLedgerTests.swift`

**Step 1: Add the endpoint to `AppConstants.WebAPI`.**

In `Constants.swift`, within the `WebAPI` enum, append (near `deviceTokens`):

```swift
static let userDeleteAccount = "/api/user/delete-account"
```

**Step 2: Write failing tests for `deleteAccount` error mapping.**

Append to `JetLedgerTests/JetLedgerTests.swift`:

```swift
@MainActor
struct AuthServiceDeleteAccountTests {

    private func makeService() -> AuthService {
        // The AuthService init hits Bundle.main for JetLedgerAPIURL via AppConstants.
        // In tests, Bundle.main points at the xctest bundle which has the Secrets-backed
        // Info.plist merged in. That's fine — we swap apiClient.session below via mock.
        let service = AuthService()
        return service
    }

    /// Replace the apiClient's URLSession with a mocked one by constructing a
    /// fresh APIClient with the mock session and swapping it in. Requires
    /// apiClient to be `var` on AuthService — see Task 3 Step 3.
    private func injectMockSession(into service: AuthService) {
        let mockClient = APIClient(
            baseURL: service.apiClient.baseURL,
            session: MockURLProtocol.makeSession()
        )
        // Preserve any cached token so auth header flows through.
        if let token = service.apiClient.sessionToken {
            mockClient.setSessionToken(token)
        }
        service.apiClient = mockClient
    }

    @Test
    func deleteAccountReturnsScheduledDateOn200() async throws {
        let service = makeService()
        injectMockSession(into: service)

        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"message":"account scheduled for deletion","deletion_scheduled_for":"2026-05-21T12:00:00Z"}"#.data(using: .utf8)!
            return (response, body)
        }

        let date = try await service.deleteAccount(
            password: "hunter2",
            confirmEmail: "user@example.com"
        )
        // The view formats the date for display; here we just check it parsed.
        #expect(date.timeIntervalSince1970 > 0)
    }

    @Test
    func deleteAccountMapsIncorrectPasswordTo401Case() async throws {
        let service = makeService()
        injectMockSession(into: service)

        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"error":"incorrect password"}"#.data(using: .utf8)!
            return (response, body)
        }

        await #expect(throws: DeleteAccountError.self) {
            _ = try await service.deleteAccount(password: "wrong", confirmEmail: "user@example.com")
        }
    }

    @Test
    func deleteAccountMapsEmailMismatchTo422Case() async throws {
        let service = makeService()
        injectMockSession(into: service)

        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 422, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"error":"email does not match"}"#.data(using: .utf8)!
            return (response, body)
        }

        do {
            _ = try await service.deleteAccount(password: "x", confirmEmail: "wrong@example.com")
            Issue.record("expected throw")
        } catch let e as DeleteAccountError {
            if case .emailMismatch = e {
                // ok
            } else {
                Issue.record("unexpected case: \(e)")
            }
        }
    }

    @Test
    func deleteAccountMapsLastAdmin409ToLastAdminCase() async throws {
        let service = makeService()
        injectMockSession(into: service)

        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            let msg = "you are the only admin on \"Acme Air\" — transfer admin role or remove other members before deleting your account"
            let body = "{\"error\":\"\(msg)\"}".data(using: .utf8)!
            return (response, body)
        }

        do {
            _ = try await service.deleteAccount(password: "x", confirmEmail: "user@example.com")
            Issue.record("expected throw")
        } catch let e as DeleteAccountError {
            if case .lastAdmin(let message) = e {
                #expect(message.contains("only admin"))
            } else {
                Issue.record("unexpected case: \(e)")
            }
        }
    }

    @Test
    func deleteAccountMapsAlreadyScheduled409ToAlreadyScheduledCase() async throws {
        let service = makeService()
        injectMockSession(into: service)

        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://example.test/api/user/delete-account")!,
                statusCode: 409, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"error":"account is already scheduled for deletion"}"#.data(using: .utf8)!
            return (response, body)
        }

        do {
            _ = try await service.deleteAccount(password: "x", confirmEmail: "user@example.com")
            Issue.record("expected throw")
        } catch let e as DeleteAccountError {
            if case .alreadyScheduled = e {
                // ok
            } else {
                Issue.record("unexpected case: \(e)")
            }
        }
    }
}
```

**Step 3: Make `AuthService.apiClient` assignable (for test injection only).**

In `AuthService.swift` line 14, change:

```swift
let apiClient: APIClient
```

to:

```swift
var apiClient: APIClient
```

This is minimal — no other source touches it by assignment, only reads. If this feels loose, leave `let` and instead update tests to create a separate `APIClient` with a mock session and pass it to a new `AuthService(apiClient:)` initializer. The `var` approach avoids adding a second initializer, but either is acceptable.

**Step 4: Run tests — expect FAIL (compile errors: `DeleteAccountError`, `deleteAccount`, `confirmEmail` not defined).**

```bash
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet -only-testing:JetLedgerTests/AuthServiceDeleteAccountTests
```

**Step 5: Implement `DeleteAccountError` and `deleteAccount`.**

In `AuthService.swift`, add above the `// MARK: - Auth DTOs` line (around line 341):

```swift
// MARK: - Account Deletion

enum DeleteAccountError: Error, LocalizedError {
    case invalidInput(message: String)          // 400
    case invalidPassword                         // 401
    case emailMismatch                           // 422
    case lastAdmin(message: String)              // 409 w/ last-admin body
    case alreadyScheduled                        // 409 w/ already-scheduled body
    case network(Error)                          // URLError
    case server(status: Int, message: String?)   // 500, unexpected statuses

    var errorDescription: String? {
        switch self {
        case .invalidInput(let m): m
        case .invalidPassword: "Incorrect password. Please try again."
        case .emailMismatch: "The email you entered doesn't match your account email."
        case .lastAdmin(let m): m
        case .alreadyScheduled: "Your account is already scheduled for deletion."
        case .network: "Unable to connect. Check your internet connection and try again."
        case .server(_, let msg): msg ?? "Something went wrong. Please try again."
        }
    }

    /// True when `DeleteAccountView` should render the "Manage accounts on the web" button.
    var isLastAdmin: Bool {
        if case .lastAdmin = self { return true }
        return false
    }
}

private struct DeleteAccountRequestBody: Encodable {
    let password: String
    let confirmEmail: String

    enum CodingKeys: String, CodingKey {
        case password
        case confirmEmail = "confirm_email"
    }
}

private struct DeleteAccountResponseBody: Decodable {
    let message: String
    let deletionScheduledFor: String

    enum CodingKeys: String, CodingKey {
        case message
        case deletionScheduledFor = "deletion_scheduled_for"
    }
}
```

Still in `AuthService`, as a public method (after `verifyMFARecovery`, before `// MARK: - Sign Out`):

```swift
// MARK: - Account Deletion

func deleteAccount(password: String, confirmEmail: String) async throws -> Date {
    let body = DeleteAccountRequestBody(password: password, confirmEmail: confirmEmail)
    let bodyData: Data
    do {
        bodyData = try APIClient.encoder.encode(body)
    } catch {
        throw DeleteAccountError.server(status: 0, message: "Failed to encode request.")
    }

    let data: Data
    let status: Int
    do {
        (data, status) = try await apiClient.performRawRequest(
            .post, AppConstants.WebAPI.userDeleteAccount, bodyData: bodyData
        )
    } catch let urlError as URLError {
        throw DeleteAccountError.network(urlError)
    } catch {
        throw DeleteAccountError.network(error)
    }

    switch status {
    case 200:
        let decoded = try APIClient.decoder.decode(DeleteAccountResponseBody.self, from: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: decoded.deletionScheduledFor) {
            return date
        }
        // Fall back without fractional seconds.
        let altFormatter = ISO8601DateFormatter()
        altFormatter.formatOptions = [.withInternetDateTime]
        if let date = altFormatter.date(from: decoded.deletionScheduledFor) {
            return date
        }
        throw DeleteAccountError.server(status: 200, message: "Could not parse scheduled deletion date.")

    case 400:
        throw DeleteAccountError.invalidInput(message: Self.errorString(from: data) ?? "Invalid request.")
    case 401:
        throw DeleteAccountError.invalidPassword
    case 409:
        let message = Self.errorString(from: data) ?? ""
        if message.lowercased().contains("already") {
            throw DeleteAccountError.alreadyScheduled
        }
        throw DeleteAccountError.lastAdmin(message: message)
    case 422:
        throw DeleteAccountError.emailMismatch
    default:
        throw DeleteAccountError.server(status: status, message: Self.errorString(from: data))
    }
}

private static func errorString(from data: Data) -> String? {
    struct Envelope: Decodable { let error: String }
    return (try? APIClient.decoder.decode(Envelope.self, from: data))?.error
}
```

**Step 6: Run tests — expect PASS.**

```bash
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet -only-testing:JetLedgerTests/AuthServiceDeleteAccountTests
```
Expected: all 5 tests pass.

**Step 7: Commit.**

```bash
git add JetLedger/Services/AuthService.swift JetLedger/Utilities/Constants.swift JetLedgerTests/
git commit -m "feat: AuthService.deleteAccount with typed DeleteAccountError mapping"
```

---

## Task 4: Add `AuthService.performFullAccountWipe()`

**Why:** After the user acknowledges the scheduled deletion on the success screen, wipe all local traces so the device is left in a clean post-deletion state.

**Files:**
- Modify: `JetLedger/Services/AuthService.swift`

**Step 1: Read existing cleanup patterns.**

Reference:
- `AuthService.signOut` (line 263) — clears biometric tokens, clears session.
- `AccountService.clearAllData` (line 166) — clears SwiftData + receipt image files + selectedAccount UserDefaults.
- `OfflineIdentity.clear()` — call site in `SettingsView.clearDeviceData` (line 176).
- `BiometricAuthService.deleteLocalTokens()` and `.resetPromptFlag()`.

**Step 2: Add `performFullAccountWipe` to `AuthService`.**

After `signOutRetainingIdentity()` (around line 296), add:

```swift
/// Wipes all local user data following successful account deletion on the server.
/// Distinct from `signOut` because (a) the server already revoked everything, so
/// no logout call is made, and (b) it clears strictly more — SwiftData, receipt
/// image files, OfflineIdentity, and user-preference UserDefaults.
///
/// `accountService` is provided by the caller (SettingsView has it via
/// `@Environment(AccountService.self)`) rather than held as a reference here,
/// keeping `AuthService` free of reverse dependencies on other services.
func performFullAccountWipe(accountService: AccountService) {
    // 1. Server-side tokens are already revoked — just clear local Keychain.
    biometricService?.deleteLocalTokens()
    biometricService?.resetPromptFlag()

    // 2. SwiftData + receipt images + selectedAccountId UserDefault.
    accountService.clearAllData()

    // 3. Offline identity.
    OfflineIdentity.clear()

    // 4. User-preference UserDefaults. Delete-account is "leave no trace".
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "hasPromptedBiometricLogin")
    defaults.removeObject(forKey: AppConstants.Cleanup.imageRetentionKey)
    defaults.removeObject(forKey: "defaultEnhancementMode")

    // 5. Session + user identity + authState. Must be last — flips root view.
    clearSession()
    authState = .unauthenticated
    errorMessage = nil
}
```

**Step 3: Build to verify it compiles.**

```bash
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```

Expected: BUILD SUCCEEDED.

**Step 4: Write a test that verifies the wipe clears expected state.**

Append to `JetLedgerTests/JetLedgerTests.swift`:

```swift
@MainActor
struct AuthServiceFullWipeTests {
    @Test
    func performFullAccountWipeClearsUserDefaultsAndSetsUnauthenticated() async throws {
        let service = AuthService()
        // Simulate post-login state.
        service.authState = .authenticated
        UserDefaults.standard.set("test-user", forKey: "hasPromptedBiometricLogin")
        UserDefaults.standard.set(30, forKey: AppConstants.Cleanup.imageRetentionKey)

        // Build an in-memory AccountService to satisfy the dependency.
        let schema = Schema([
            LocalReceipt.self,
            LocalReceiptPage.self,
            CachedAccount.self,
            CachedTripReference.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let accountService = AccountService(
            apiClient: service.apiClient,
            modelContext: container.mainContext
        )

        service.performFullAccountWipe(accountService: accountService)

        #expect(service.authState == .unauthenticated)
        #expect(UserDefaults.standard.object(forKey: "hasPromptedBiometricLogin") == nil)
        #expect(UserDefaults.standard.object(forKey: AppConstants.Cleanup.imageRetentionKey) == nil)
    }
}
```

**Step 5: Run the test — expect PASS.**

```bash
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet -only-testing:JetLedgerTests/AuthServiceFullWipeTests
```

**Step 6: Commit.**

```bash
git add JetLedger/Services/AuthService.swift JetLedgerTests/
git commit -m "feat: AuthService.performFullAccountWipe for post-deletion cleanup"
```

---

## Task 5: Create `DeleteAccountView`

**Files:**
- Create: `JetLedger/Views/Settings/DeleteAccountView.swift`

**Step 1: Create the new view file.**

```swift
//
//  DeleteAccountView.swift
//  JetLedger
//

import SwiftUI

struct DeleteAccountView: View {
    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Phase {
        case form
        case submitting
        case success(Date)
    }

    @State private var password = ""
    @State private var emailConfirmation = ""
    @State private var phase: Phase = .form
    @State private var error: DeleteAccountError?

    private var accountEmail: String {
        accountService.userProfile?.email
            ?? authService.currentUserEmail
            ?? ""
    }

    private var isFormValid: Bool {
        !password.isEmpty
            && !emailConfirmation.isEmpty
            && emailConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(accountEmail) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .form:
                    formView
                case .submitting:
                    submittingView
                case .success(let date):
                    successView(date: date)
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if case .success = phase {
                        // No cancel on success — user must tap Done.
                    } else {
                        Button("Cancel") { dismiss() }
                            .disabled({
                                if case .submitting = phase { return true }
                                return false
                            }())
                    }
                }
            }
            .interactiveDismissDisabled({
                switch phase {
                case .submitting, .success: return true
                case .form: return false
                }
            }())
        }
    }

    // MARK: - Form

    private var formView: some View {
        Form {
            Section {
                Text("This will permanently delete your account and all associated data after a 30-day grace period. To cancel during that window, contact support.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Confirm your password") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityLabel("Password")
            }

            Section {
                TextField("Type your email to confirm", text: $emailConfirmation)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type your email to confirm")
            } header: {
                Text("Confirm your email")
            } footer: {
                Text(accountEmail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Section {
                    Text(error.localizedDescription)
                        .font(.callout)
                        .foregroundStyle(.red)
                    if error.isLastAdmin {
                        Button {
                            openURL(AppConstants.Links.webApp)
                        } label: {
                            Label("Manage accounts on the web", systemImage: "safari")
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    submit()
                } label: {
                    Text("Delete Account")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!isFormValid)
            }
        }
    }

    private var submittingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Scheduling account deletion…")
                .font(.headline)
            Spacer()
        }
    }

    private func successView(date: Date) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Account scheduled for deletion")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Your account and all data will be permanently deleted on \(formatted(date)).")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Text("Contact support to cancel before then.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                authService.performFullAccountWipe(accountService: accountService)
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }

    // MARK: - Actions

    private func submit() {
        error = nil
        let notifier = UINotificationFeedbackGenerator()
        notifier.notificationOccurred(.warning)
        phase = .submitting
        Task {
            do {
                let date = try await authService.deleteAccount(
                    password: password,
                    confirmEmail: emailConfirmation
                )
                phase = .success(date)
            } catch let e as DeleteAccountError {
                error = e
                phase = .form
            } catch {
                self.error = .server(status: 0, message: error.localizedDescription)
                phase = .form
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
```

**Step 2: Build.**

```bash
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```
Expected: BUILD SUCCEEDED. (No test — view is verified manually in Task 8.)

**Step 3: Commit.**

```bash
git add JetLedger/Views/Settings/DeleteAccountView.swift
git commit -m "feat: DeleteAccountView with form, submitting, and success states"
```

---

## Task 6: Wire `DeleteAccountView` into `SettingsView`

**Files:**
- Modify: `JetLedger/Views/Settings/SettingsView.swift`

**Step 1: Add state + section + sheet.**

In `SettingsView.swift`, add a new `@State` near the existing ones (around line 23):

```swift
@State private var showDeleteAccount = false
```

After the `// MARK: Clear Device Data` section (the one ending at line 128), add:

```swift
// MARK: Danger Zone
if !isOfflineMode {
    Section {
        Button(role: .destructive) {
            showDeleteAccount = true
        } label: {
            Text("Delete Account")
        }
    } header: {
        Text("Danger Zone")
    } footer: {
        Text("Permanently delete your account and all associated data. Subject to a 30-day grace period during which deletion can be canceled by contacting support.")
    }
}
```

Add the sheet modifier at the end of the outer `NavigationStack`'s `.alert(...)` chain (after the existing `Clear Device Data?` alert, line 155):

```swift
.sheet(isPresented: $showDeleteAccount) {
    DeleteAccountView()
}
```

**Step 2: Build.**

```bash
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```
Expected: BUILD SUCCEEDED.

**Step 3: Commit.**

```bash
git add JetLedger/Views/Settings/SettingsView.swift
git commit -m "feat: add Danger Zone section with Delete Account entry in Settings"
```

---

## Task 7: Full build + full test run

**Step 1: Clean build.**

```bash
xcodebuild clean -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet
xcodebuild -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet build
```
Expected: BUILD SUCCEEDED.

**Step 2: Run all tests.**

```bash
xcodebuild test -scheme JetLedger -destination 'platform=iOS Simulator,id=BE3394BC-9EE2-452E-8770-CA021987D8F0' -quiet
```
Expected: all tests pass (existing `TripReferenceServiceTests` + new `APIClientRawRequestTests`, `AuthServiceDeleteAccountTests`, `AuthServiceFullWipeTests`).

---

## Task 8: Manual UI verification checklist

**Context:** Swift Testing covers error mapping and wipe logic, but the UI flow must be exercised in Simulator (or on device). @superpowers:verification-before-completion.

For each item, tap through the flow on the iOS Simulator and verify the stated outcome. Do NOT claim this task complete without running it.

1. **Entry point visible.** Sign in → Settings. "Danger Zone" section appears at the bottom with a red "Delete Account" button and explanatory footer.
2. **Sheet presentation.** Tap "Delete Account" → `DeleteAccountView` appears as a sheet with title "Delete Account". Cancel button in top-left; dismissing via swipe works in the form state.
3. **Submit disabled on invalid input.** Leave password blank, type correct email → "Delete Account" button disabled. Type password, type wrong email → still disabled. Type matching email (case-insensitive) → enabled.
4. **Wrong password path.** Submit with wrong password → brief progress spinner → form returns with red error: "Incorrect password. Please try again." Verify Face ID is NOT prompted.
5. **Happy path.** Submit with correct password + correct email. Expect: progress spinner briefly, then success screen with green check, "Account scheduled for deletion" heading, formatted date, Done button. Tap Done → returns to login screen; no residual account/receipt data visible.
6. **Relaunch after Done.** Force-quit and relaunch → lands on login screen (no session, no biometric device token, no accounts cached).
7. **Last-admin block.** Requires a test account that is the sole admin of a multi-member account. Submit → form returns with the server's last-admin message and a "Manage accounts on the web" button that opens Safari to `jetledger.io`.
8. **Network loss mid-submit.** Turn off network in simulator, submit → error: "Unable to connect. Check your internet connection and try again." Network back on → retry works.
9. **VoiceOver.** Rotor to focus password field → reads "Password". Focus email field → reads "Type your email to confirm". Focus submit button → reads "Delete Account, button, disabled" when form invalid.
10. **Dark mode.** Toggle simulator appearance to dark → all three states render with appropriate foreground/background contrast; red button text remains legible.

Document any findings before marking complete.

---

## Out of scope (not in this plan)

- Server-side backend changes (endpoint already exists).
- In-app "cancel deletion" flow during the 30-day grace period (web + support only).
- Pre-flight last-admin detection API.
- Localization (hardcoded English per `CLAUDE.md`).
- Apple Developer App Store submission paperwork (separate TODO).
