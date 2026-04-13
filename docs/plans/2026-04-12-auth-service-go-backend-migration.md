# AuthService Migration: Supabase to Go Backend

**Date:** 2026-04-12
**Status:** Approved

## Summary

Replace the Supabase SDK-based authentication layer with direct HTTP calls to the JetLedger Go backend's iOS auth API. This removes the only third-party dependency (`supabase-swift`) and unifies all API communication through a shared `APIClient`.

## Go Backend Auth API (already built)

| Endpoint | Purpose | Auth Required |
|----------|---------|---------------|
| `POST /api/auth/login` | Email + password login | No |
| `POST /api/auth/verify-totp` | TOTP or recovery code verification | No (uses mfa_token) |
| `POST /api/auth/refresh` | Token rotation | Yes (Bearer) |
| `POST /api/auth/logout` | Session termination | Yes (Bearer) |
| `GET /api/accounts` | List user's accounts with roles | Yes (Bearer) |
| `GET/POST/PUT /api/trip-references` | Trip reference CRUD | Yes (Bearer + X-Account-ID) |
| `POST/DELETE /api/user/device-tokens` | Push notification tokens | Yes (Bearer) |

**Token model:** Opaque base64 token (32 random bytes), SHA-256 hashed server-side. 30-day lifetime. MFA pending tokens have 5-minute lifetime.

**Login response shape:**
```json
{
  "session_token": "base64_token",        // omitted if mfa_required
  "mfa_required": true,                   // omitted if no MFA
  "mfa_token": "temporary_5min_token",    // omitted if no MFA
  "user": { "id", "email", "first_name", "last_name" },
  "accounts": [{ "id", "name", "slug", "role", "is_default" }]  // omitted if mfa_required
}
```

## Design

### 1. APIClient (new file: `Services/APIClient.swift`)

Extracted from `ReceiptAPIService`'s existing HTTP plumbing. Shared by all services.

**Responsibilities:**
- Owns the session token (Keychain read/write via `KeychainHelper`)
- Injects `Authorization: Bearer <token>` when token exists
- Injects `X-Account-ID` header when `accountId` is set
- Typed request/response helpers (JSON encode/decode)
- `APIError` enum (moved from ReceiptAPIService)
- On 401 from any request: fires `onUnauthorized` closure (no automatic retry for v1 -- 30-day tokens mean expiry = genuine re-login needed)

**Key API surface:**
```swift
class APIClient {
    let baseURL: URL
    var accountId: UUID?                    // set by AccountService on selection
    var onUnauthorized: (() -> Void)?       // set by AuthService
    
    var sessionToken: String? { get }
    func setSessionToken(_ token: String)
    func clearSessionToken()
    
    func request<R: Decodable>(_ method: HTTPMethod, _ path: String) async throws -> R
    func request<R: Decodable>(_ method: HTTPMethod, _ path: String, body: some Encodable) async throws -> R
    func requestVoid(_ method: HTTPMethod, _ path: String, body: some Encodable) async throws
    func get<R: Decodable>(_ path: String, query: [String: String]) async throws -> R
}
```

Bearer header is injected automatically when `sessionToken` is non-nil. Auth endpoints (login, verify-totp) work without a token since no header is added.

### 2. KeychainHelper (new file: `Utilities/KeychainHelper.swift`)

Simple wrapper around Security framework for session token storage. The Supabase SDK previously handled this internally.

**Operations:** `save(key, data)`, `read(key) -> Data?`, `delete(key)`.

### 3. AuthService rewrite (`Services/AuthService.swift`)

**Owns:** Auth state machine, login/MFA orchestration. Uses APIClient for HTTP, delegates token storage to APIClient's Keychain.

**Public API:**
```swift
@Observable
class AuthService {
    var authState: AuthState = .loading
    var errorMessage: String?
    let apiClient: APIClient
    
    var currentUserId: UUID?
    var currentUserEmail: String?
    var loginAccounts: [APIAccount]?   // transient, consumed by AccountService on .authenticated
    var loginProfile: APIUser?         // transient, consumed by AccountService
    
    func signIn(email: String, password: String) async
    func verifyMFA(code: String, mfaToken: String) async
    func verifyMFARecovery(code: String, mfaToken: String) async
    func signOut() async
    func signOutRetainingIdentity() async
    func enterOfflineMode()
    func restoreSession() async
}
```

**Removed:**
- `supabase: SupabaseClient` property
- All password reset methods and state (`resetPasswordForEmail`, `handlePasswordResetDeepLink`, `verifyMFAForPasswordReset`, `updatePassword`, `cancelPasswordReset`, `isPasswordResetActive`, `passwordResetMFAFactorId`, `passwordResetEmail`, `passwordResetTimeoutTask`)
- MFA enrollment check (`checkMFARequired`, `retryAfterMFAEnrollment`)
- `listenForAuthChanges` (no Supabase auth stream)

**Login flow:**
1. `signIn` -> `POST /api/auth/login`
   - `mfa_required: true` -> `authState = .mfaRequired(mfaToken:)`
   - Otherwise -> store token, save user/accounts, `authState = .authenticated`
2. `verifyMFA` / `verifyMFARecovery` -> `POST /api/auth/verify-totp` with `{mfa_token, code}` or `{mfa_token, recovery_code}`
   - Store token, save user/accounts, `authState = .authenticated`
3. `signOut` -> `POST /api/auth/logout`, clear Keychain
4. `restoreSession` (app launch) -> check Keychain for token. Present -> `.authenticated`. Absent -> `.unauthenticated`.

**Stored session data:**
- Keychain: `session_token` (opaque bearer token)
- UserDefaults: `currentUserId`, `currentUserEmail` (non-sensitive, needed for OfflineIdentity comparison before network calls)

### 4. AuthState enum change (`Models/Enums.swift`)

```swift
enum AuthState: Equatable, Sendable {
    case loading
    case unauthenticated
    case mfaRequired(mfaToken: String)  // was: mfaRequired(factorId: String)
    // mfaEnrollmentRequired -- REMOVED
    case authenticated
    case offlineReady
}
```

### 5. Service wiring changes (`JetLedgerApp.swift`)

**New wiring:**
```
AuthService creates APIClient (Keychain-backed token)
  -> APIClient shared with AccountService, TripReferenceService
  -> ReceiptAPIService takes APIClient (not baseURL + sessionProvider)
  -> SyncService drops SupabaseClient param
  -> AuthService.apiClient.onUnauthorized -> authState = .unauthenticated
```

**`.authenticated` state handler:**
1. `AccountService` seeded from `authService.loginAccounts` (from login response) -- no extra network call on first login
2. `AccountService.loadAccounts()` still exists for pull-to-refresh
3. Profile data comes from `authService.loginProfile` -- no separate profile endpoint
4. `OfflineIdentity` populated from `authService.currentUserId` + account data
5. Deep link `.onOpenURL` for password reset removed entirely

**Session restore:** `.task` modifier calls `authService.restoreSession()` instead of relying on `listenForAuthChanges`.

### 6. AccountService migration (`Services/AccountService.swift`)

- Init: `APIClient` + `ModelContext` (drop SupabaseClient)
- New `seedAccounts(_ accounts: [APIAccount])`: caches login-response accounts to SwiftData, sets selection. Called during `.authenticated` wiring.
- `loadAccounts()` -> `GET /api/accounts` via APIClient (refresh/pull-to-refresh)
- `loadProfile()` removed -- profile comes from login response
- `supabase.auth.currentSession?.user.id` -> userId from AuthService
- DTOs updated to match Go API shape

### 7. TripReferenceService migration (`Services/TripReferenceService.swift`)

- Init: `APIClient` + `ModelContext` + `NetworkMonitor` (drop SupabaseClient)
- `loadTripReferences(for:)` -> `GET /api/trip-references?account_id=...` via APIClient
- `createTripReferenceLocally()` online path -> `POST /api/trip-references` via APIClient
- `syncSingleTripReference()` -> `POST /api/trip-references` via APIClient
- `handleUniqueConflict()` -> `GET /api/trip-references?...` via APIClient
- `updateTripReference()` -> `PUT /api/trip-references/{id}` via APIClient
- `PostgrestError` catch for unique violation -> HTTP 409 or error response from Go API
- Remove `import PostgREST`, `import Supabase`

### 8. SyncService changes (`Services/SyncService.swift`)

Minimal:
- Drop `supabase: SupabaseClient` from init
- Line 324 (`supabase.auth.currentSession?.user.id`) -> accept userId via closure or parameter
- Remove `import Supabase`

### 9. ReceiptAPIService refactor (`Services/ReceiptAPIService.swift`)

Becomes a thin wrapper over APIClient:
- Init: `APIClient` (not baseURL + sessionProvider)
- Methods stay the same externally
- Internal plumbing (`authorizeRequest`, `validateResponse`, `post<Body, Response>`, `URLSession`, JSON coders) removed -- delegated to APIClient
- `APIError` enum moves to APIClient
- DTOs stay in ReceiptAPIService

### 10. View changes

**MFAVerifyView** -- add recovery code support:
- `useRecoveryCode: Bool` toggle
- Default: 6-digit TOTP field with "Use recovery code" link below
- Toggle swaps to single text field for `XXXXXXXX-XXXXXXXX` format
- "Use TOTP code" link to swap back
- Submit calls `verifyMFA` or `verifyMFARecovery` based on toggle
- `factorId` parameter -> `mfaToken`

**AuthFlowView:**
- Remove `.mfaEnrollmentRequired` case
- Update `.mfaRequired(let mfaToken)` binding

**LoginView:**
- Remove "Forgot password?" button (or replace with static "Reset password at jetledger.io" text)

### 11. Files to delete

- `Views/Login/PasswordResetView.swift`
- `Views/Login/MFAEnrollmentRequiredView.swift`

### 12. Dependency and config cleanup

**Remove:** `supabase-swift` SPM package (zero third-party dependencies after this)

**Constants.swift:**
- Delete `AppConstants.Supabase` enum
- Add auth paths to `AppConstants.WebAPI`: `/api/auth/login`, `/api/auth/verify-totp`, `/api/auth/refresh`, `/api/auth/logout`, `/api/accounts`, `/api/trip-references`

**Secrets.xcconfig:**
- Remove `SUPABASE_URL`, `SUPABASE_ANON_KEY`
- `JETLEDGER_API_URL` stays

**Info.plist:**
- Remove `SupabaseURL`, `SupabaseAnonKey` entries

## Files changed (summary)

| File | Change |
|------|--------|
| `Services/APIClient.swift` | **NEW** -- shared HTTP client |
| `Utilities/KeychainHelper.swift` | **NEW** -- Keychain wrapper for token |
| `Services/AuthService.swift` | **REWRITE** -- Go API auth |
| `Services/AccountService.swift` | **MODIFY** -- APIClient, seed from login |
| `Services/TripReferenceService.swift` | **MODIFY** -- APIClient |
| `Services/SyncService.swift` | **MODIFY** -- drop SupabaseClient |
| `Services/ReceiptAPIService.swift` | **MODIFY** -- thin wrapper over APIClient |
| `Models/Enums.swift` | **MODIFY** -- AuthState changes |
| `JetLedgerApp.swift` | **MODIFY** -- new wiring, remove deep link |
| `Views/Login/MFAVerifyView.swift` | **MODIFY** -- recovery codes, mfaToken |
| `Views/Login/AuthFlowView.swift` | **MODIFY** -- remove enrollment case |
| `Views/Login/LoginView.swift` | **MODIFY** -- remove password reset |
| `Utilities/Constants.swift` | **MODIFY** -- remove Supabase, add paths |
| `Secrets.xcconfig` | **MODIFY** -- remove Supabase keys |
| `Views/Login/PasswordResetView.swift` | **DELETE** |
| `Views/Login/MFAEnrollmentRequiredView.swift` | **DELETE** |
