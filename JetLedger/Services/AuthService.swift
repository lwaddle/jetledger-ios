//
//  AuthService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog

@Observable
class AuthService {
    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "AuthService")
    var authState: AuthState = .loading
    var errorMessage: String?

    var apiClient: APIClient

    var currentUserId: UUID?
    var currentUserEmail: String?
    var loginAccounts: [LoginAccount]?
    var loginProfile: LoginUser?

    /// Optional — injected by JetLedgerApp. Nil on devices that don't advertise
    /// Associated Domains or in test harnesses that don't need passkey support.
    var passkeyService: PasskeyAuthService?

    private static let userIdKey = "currentUserId"
    private static let userEmailKey = "currentUserEmail"

    init() {
        apiClient = APIClient(baseURL: AppConstants.WebAPI.baseURL)
        apiClient.onUnauthorized = { [weak self] in
            guard let self else { return }
            // Biometric re-auth fires only from `.authenticated` — a session that
            // just expired mid-use. In `.offlineReady` the bearer token was cleared
            // intentionally by sign-out; silently re-authenticating there would
            // undo the user's explicit action (observed bug: tapping Sign Out with
            // Face ID enabled triggered a device-login round-trip that signed the
            // user back in).
            guard self.authState == .authenticated else { return }
            if let bioService = self.biometricService,
               bioService.isBiometricLoginEnabled,
               !self.isReauthenticating {
                self.isReauthenticating = true
                Task {
                    defer { self.isReauthenticating = false }
                    // The guard above ran synchronously at 401 time; an explicit
                    // sign-out may have completed between then and this task
                    // running. Re-check before prompting Face ID and again
                    // before adopting the session, so recovery never overrides
                    // a deliberate state change.
                    guard self.authState == .authenticated else { return }
                    if let response = await bioService.attemptBiometricLogin(apiClient: self.apiClient) {
                        guard self.authState == .authenticated else { return }
                        // The device token belongs to whoever enrolled it. On a
                        // shared device, silently adopting it could swap user B's
                        // expired session for user A's — and route B's uploads
                        // into A's account.
                        if let currentId = self.currentUserId,
                           UUID(uuidString: response.user.id) != currentId {
                            self.forceSignOut()
                        } else {
                            self.handleLoginResponse(response)
                        }
                    } else {
                        self.forceSignOut()
                    }
                }
            } else if !self.isReauthenticating {
                self.forceSignOut()
            }
        }
        // The backstop can be the first place the app learns it's behind — a
        // landing-time upload burst races the foreground accounts refresh.
        apiClient.onTermsAcceptanceRequired = { [weak self] payload in
            guard let self, self.authState == .authenticated else { return }
            self.termsStatus = TermsStatus.from403(payload, merging: self.termsStatus)
        }
        // Restore cached user info for OfflineIdentity comparison
        currentUserId = UserDefaults.standard.string(forKey: Self.userIdKey).flatMap(UUID.init)
        currentUserEmail = UserDefaults.standard.string(forKey: Self.userEmailKey)
    }

    /// Set by JetLedgerApp after creating BiometricAuthService.
    var biometricService: BiometricAuthService?

    /// Set by JetLedgerApp after creating PushNotificationService.
    var pushService: PushNotificationService?

    private var isReauthenticating = false

    // MARK: - Terms Re-acceptance

    /// The latest terms signal, from a live server response only: the `terms`
    /// object on a session-creating auth response or `GET /api/accounts`, or a
    /// synthesized status from the typed 403 backstop. Deliberately in-memory —
    /// **the gate fails OPEN offline**, and a persisted flag is exactly the
    /// stale state that would block a pilot capturing receipts at altitude. An
    /// online cold launch re-learns the state via the accounts fetch it already
    /// performs; an offline launch never gates.
    var termsStatus: TermsStatus?

    /// Drives the blocking gate over `MainView`. True only on the strength of
    /// a fresh successful response with `acceptance_required: true` or the
    /// typed 403 — a transport error never blocks UI.
    var termsAcceptanceRequired: Bool { termsStatus?.acceptanceRequired == true }

    /// Applies the `terms` object from a signal-bearing response. `nil` — an
    /// older server that doesn't send the object — clears any gate: the client
    /// keys off `acceptance_required` only, and absence of a signal is never a
    /// block.
    func applyTermsStatus(_ status: TermsStatus?) {
        termsStatus = status
    }

    enum TermsAcceptOutcome: Equatable {
        case accepted
        /// 409 — the published version moved between fetch and accept. The
        /// gate re-presents with the new version; never silently retried with
        /// a version the user wasn't shown.
        case versionChanged
        case failed(message: String)
    }

    /// Records acceptance of the version currently displayed by the gate.
    /// Echoing that version is the point of the request body: it proves what
    /// the user was shown. Uses `performRawRequest` because the 409 body must
    /// be read (`request()` collapses it into an opaque `.conflict`).
    func acceptCurrentTerms() async -> TermsAcceptOutcome {
        guard let status = termsStatus else {
            return .failed(message: "Something went wrong. Please try again.")
        }

        let bodyData: Data
        do {
            bodyData = try APIClient.encoder.encode(TermsAcceptRequest(termsVersion: status.currentVersion))
        } catch {
            return .failed(message: "Something went wrong. Please try again.")
        }

        let data: Data
        let httpStatus: Int
        do {
            (data, httpStatus) = try await apiClient.performRawRequest(
                .post, AppConstants.WebAPI.termsAccept, bodyData: bodyData
            )
        } catch {
            return .failed(message: "Unable to connect. Check your internet connection and try again.")
        }

        switch httpStatus {
        case 200:
            if let response = try? APIClient.decoder.decode(TermsAcceptResponse.self, from: data) {
                termsStatus = response.terms
            } else {
                // Recorded server-side but the refreshed signal didn't parse.
                // The acceptance is real, so clear the gate locally; the next
                // accounts refresh restores the authoritative signal.
                termsStatus = TermsStatus(
                    currentVersion: status.currentVersion,
                    acceptedVersion: status.currentVersion,
                    acceptanceRequired: false,
                    termsUrl: status.termsUrl,
                    privacyUrl: status.privacyUrl
                )
            }
            return .accepted
        case 401:
            // Raw requests bypass the standard 401 handling — run it explicitly
            // so a dead session recovers (biometric re-auth) instead of leaving
            // the gate up over an accept that can only ever 401.
            apiClient.onUnauthorized?()
            return .failed(message: "Your session expired. Please sign in again.")
        case 409:
            struct MismatchBody: Decodable {
                let currentVersion: String
                enum CodingKeys: String, CodingKey { case currentVersion = "current_version" }
            }
            if let body = try? APIClient.decoder.decode(MismatchBody.self, from: data) {
                termsStatus = TermsStatus(
                    currentVersion: body.currentVersion,
                    acceptedVersion: status.acceptedVersion,
                    acceptanceRequired: true,
                    termsUrl: status.termsUrl,
                    privacyUrl: status.privacyUrl
                )
            }
            return .versionChanged
        default:
            return .failed(message: Self.errorString(from: data) ?? "Something went wrong. Please try again.")
        }
    }

    // MARK: - Session Restore

    func restoreSession() async {
        if apiClient.sessionToken != nil {
            authState = .authenticated
        } else if let bioService = biometricService, bioService.isBiometricLoginEnabled {
            // Don't fire a Face ID prompt for a device-login that cannot
            // succeed — an offline cold launch goes straight to offline mode
            // (or login) instead of a guaranteed-to-fail biometric ceremony.
            guard await apiClient.probeConnectivity() else {
                authState = OfflineIdentity.load() != nil ? .offlineReady : .unauthenticated
                return
            }
            // No session token but we have a biometric device token — try Face ID
            if let response = await bioService.attemptBiometricLogin(apiClient: apiClient) {
                handleLoginResponse(response)
            } else {
                authState = .unauthenticated
            }
        } else {
            authState = .unauthenticated
        }
    }

    // MARK: - Session Refresh

    /// Server sessions last 30 days and are only extended by explicit rotation
    /// (`POST /api/auth/refresh`) — the API middleware never rolls expiry on use,
    /// so without this an active user gets hard-logged-out every 30 days.
    /// Refreshing once the token is about a week old keeps sessions effectively
    /// rolling while keeping rotations rare: the server deletes the old session
    /// before the new token reaches us, so a response lost in transit orphans the
    /// session (recovered by the 401 → biometric re-auth path).
    private static let sessionExpiresAtKey = "sessionExpiresAt"
    private static let sessionLifetime: TimeInterval = 30 * 24 * 3600
    private static let refreshAfter: TimeInterval = 7 * 24 * 3600

    private var isRefreshingSession = false

    func refreshSessionIfNeeded() async {
        guard authState == .authenticated,
              apiClient.sessionToken != nil,
              !isRefreshingSession else { return }

        // Tokens stored before expiry tracking existed have no recorded expiry —
        // fall through and refresh immediately to establish one.
        if let expiresAt = storedSessionExpiry(),
           expiresAt.timeIntervalSinceNow > Self.sessionLifetime - Self.refreshAfter {
            return
        }

        isRefreshingSession = true
        defer { isRefreshingSession = false }

        // Rotation deletes the old session server-side before the new token is
        // stored here, so other requests are gated for the duration — otherwise
        // a concurrent status-sync can fire with the just-deleted token and 401
        // into a spurious Face ID prompt. Uses performRawRequest: the refresh
        // call itself must bypass the gate, and its 401 is handled explicitly.
        let gate = Task { [self] in
            do {
                let (data, status) = try await apiClient.performRawRequest(
                    .post, AppConstants.WebAPI.authRefresh
                )
                switch status {
                case 200:
                    let response = try APIClient.decoder.decode(RefreshResponse.self, from: data)
                    apiClient.setSessionToken(response.sessionToken)
                    storeSessionExpiry(Self.parseServerDate(response.expiresAt)
                        ?? Date().addingTimeInterval(Self.sessionLifetime))
                case 401:
                    // Session already dead — run the standard recovery path
                    // (biometric re-auth, else forced sign-out).
                    apiClient.onUnauthorized?()
                default:
                    break // 5xx — keep the current token, retry on a later foreground
                }
            } catch {
                // Network error — keep the current token, retry on a later foreground.
            }
        }
        apiClient.refreshGate = gate
        await gate.value
        apiClient.refreshGate = nil
    }

    /// Go emits RFC3339 with fractional seconds when they're non-zero, so both
    /// formats must parse.
    private static func parseServerDate(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private func storedSessionExpiry() -> Date? {
        let timestamp = UserDefaults.standard.double(forKey: Self.sessionExpiresAtKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private func storeSessionExpiry(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.sessionExpiresAtKey)
    }

    private func clearSessionExpiry() {
        UserDefaults.standard.removeObject(forKey: Self.sessionExpiresAtKey)
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
        } catch let error as APIError where error == .unauthorized() {
            Self.logger.warning("Login rejected with 401: \(error.serverMessage ?? "<no server message>", privacy: .public)")
            if let serverMessage = error.serverMessage, serverMessage != "invalid credentials" {
                // A 401 whose reason isn't the credentials check (middleware,
                // proxy, future server change) is more useful verbatim than
                // masked behind the standard copy.
                errorMessage = "Sign-in failed: \(serverMessage)"
            } else {
                errorMessage = "Invalid email or password."
            }
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
        } catch let error as APIError {
            errorMessage = mfaErrorMessage(from: error, fallback: "Invalid code. Please try again.")
        } catch is URLError {
            errorMessage = "Unable to connect. Check your internet connection."
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    /// Runs the full WebAuthn assertion ceremony for a pending-MFA session:
    /// server /begin → platform authenticator → server /finish. On success, logs
    /// the user in. Throws `PasskeyError.cancelled` if the user dismisses the
    /// system prompt, so the caller can fall back to TOTP silently.
    func verifyMFAWithPasskey(mfaToken: String) async throws {
        errorMessage = nil

        guard let passkeyService else {
            throw PasskeyError.ceremonyFailed("passkey service not configured")
        }

        // 1. Fetch challenge from the server.
        let beginBody = WebAuthnBeginRequest(mfaToken: mfaToken)
        let beginResponse: WebAuthnBeginResponse
        do {
            beginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authWebAuthnBegin, body: beginBody
            )
        } catch let error as APIError {
            let msg = mfaErrorMessage(from: error, fallback: "Could not start passkey sign-in. Please try again.")
            errorMessage = msg
            throw PasskeyError.ceremonyFailed(msg)
        } catch is URLError {
            errorMessage = "Unable to connect. Check your internet connection."
            throw PasskeyError.ceremonyFailed("network error")
        }

        // 2. Invoke platform authenticator. Cancellation bubbles up untouched so
        //    the caller can show the TOTP fallback without a scary error banner.
        let assertion: PasskeyAssertion
        do {
            assertion = try await passkeyService.performAssertion(options: beginResponse.options)
        } catch PasskeyError.cancelled {
            throw PasskeyError.cancelled
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }

        // 3. Hand the assertion to the server to complete MFA.
        do {
            let finishBody = WebAuthnFinishRequest(mfaToken: mfaToken, assertion: assertion.jsonEnvelope)
            let response: LoginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authWebAuthnFinish, body: finishBody
            )
            handleLoginResponse(response)
        } catch let error as APIError {
            let msg = mfaErrorMessage(from: error, fallback: "Passkey sign-in failed. Please try again.")
            errorMessage = msg
            throw PasskeyError.ceremonyFailed(msg)
        } catch is URLError {
            errorMessage = "Unable to connect. Check your internet connection."
            throw PasskeyError.ceremonyFailed("network error")
        }
    }

    /// Passwordless sign-in. Runs the full discoverable-credential ceremony:
    /// server `/passkey/begin` → OS passkey picker → server `/passkey/finish`.
    /// The server resolves the user from the credential ID and issues a full
    /// session directly — WebAuthn with user verification satisfies MFA per spec.
    /// Throws `PasskeyError.cancelled` if the user dismisses the system prompt
    /// so the caller can quietly return to the email/password form.
    func signInWithPasskey() async throws {
        errorMessage = nil

        guard let passkeyService else {
            throw PasskeyError.ceremonyFailed("passkey service not configured")
        }

        let beginResponse: PasskeyBeginResponse
        do {
            beginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authPasskeyBegin
            )
        } catch let error as APIError {
            let msg = error.serverMessage ?? "Could not start passkey sign-in. Please try again."
            errorMessage = msg
            throw PasskeyError.ceremonyFailed(msg)
        } catch is URLError {
            errorMessage = "Unable to connect. Check your internet connection."
            throw PasskeyError.ceremonyFailed("network error")
        }

        let assertion: PasskeyAssertion
        do {
            assertion = try await passkeyService.performDiscoverableAssertion(options: beginResponse.options)
        } catch PasskeyError.cancelled {
            throw PasskeyError.cancelled
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }

        do {
            let finishBody = PasskeyFinishRequest(
                challengeToken: beginResponse.challengeToken,
                assertion: assertion.jsonEnvelope
            )
            let response: LoginResponse = try await apiClient.request(
                .post, AppConstants.WebAPI.authPasskeyFinish, body: finishBody
            )
            handleLoginResponse(response)
        } catch let error as APIError {
            let msg = error.serverMessage ?? "Passkey sign-in failed. Please try again."
            errorMessage = msg
            throw PasskeyError.ceremonyFailed(msg)
        } catch is URLError {
            errorMessage = "Unable to connect. Check your internet connection."
            throw PasskeyError.ceremonyFailed("network error")
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
        } catch let error as APIError {
            errorMessage = mfaErrorMessage(from: error, fallback: "Invalid recovery code. Please try again.")
        } catch is URLError {
            errorMessage = "Unable to connect. Check your internet connection."
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    private func mfaErrorMessage(from error: APIError, fallback: String) -> String {
        guard let msg = error.serverMessage else { return fallback }
        if msg.contains("expired") {
            return "Your verification session expired. Please sign in again."
        } else if msg.contains("already used") {
            return "Code already used. Wait for a new code from your authenticator."
        }
        return fallback
    }

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
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: decoded.deletionScheduledFor) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: decoded.deletionScheduledFor) {
                return date
            }
            throw DeleteAccountError.invalidResponse(message: "Could not parse scheduled deletion date.")

        case 400:
            throw DeleteAccountError.invalidInput(message: Self.errorString(from: data) ?? "Invalid request.")
        case 401:
            throw DeleteAccountError.invalidPassword
        case 409:
            let message = Self.errorString(from: data)
            // The server returns two distinct 409s: last-admin and already-scheduled.
            // Match on "admin" (stable signal — describes the technical condition) rather
            // than "already" (copy-level wording that could change without breaking intent).
            if let m = message, m.lowercased().contains("admin") {
                throw DeleteAccountError.lastAdmin(message: m)
            }
            throw DeleteAccountError.alreadyScheduled
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

    // MARK: - MFA Cancel

    /// Abandon a pending MFA verification and return to the login form. There
    /// is no session to log out of yet (only a pending mfa_token, which the
    /// server expires in 5 minutes), and the device's biometric enrollment
    /// belongs to whoever enrolled it — a full signOut() here would destroy
    /// that enrollment locally while its doomed logout call (401, no session)
    /// leaves the trusted device orphaned server-side.
    func cancelMFA() {
        errorMessage = nil
        authState = .unauthenticated
    }

    // MARK: - Sign Out

    /// Called before session is cleared so services can make authenticated cleanup calls.
    var onWillSignOut: (() async -> Void)?

    func signOut() async {
        await onWillSignOut?()
        do {
            // If biometric login is enabled, pass the device token to revoke it server-side.
            if let deviceToken = biometricService?.storedDeviceToken() {
                try await apiClient.requestVoid(
                    .post, AppConstants.WebAPI.authLogout,
                    body: DeviceLoginRequest(deviceToken: deviceToken)
                )
            } else {
                try await apiClient.requestVoid(.post, AppConstants.WebAPI.authLogout)
            }
        } catch {
            // Clear local state even if server sign-out fails
        }
        // Clean up biometric state
        biometricService?.deleteLocalTokens()
        biometricService?.resetPromptFlag()
        clearSession()
        authState = .unauthenticated
        errorMessage = nil
    }

    func signOutRetainingIdentity() async {
        await onWillSignOut?()
        do {
            try await apiClient.requestVoid(.post, AppConstants.WebAPI.authLogout)
        } catch {
            // Clear local state even if server sign-out fails
        }
        apiClient.clearSessionToken()
        clearSessionExpiry()
        // Offline mode never gates; a re-login fetches a fresh signal.
        termsStatus = nil
        authState = .offlineReady
        errorMessage = nil
    }

    /// Wipes all local user data following successful account deletion on the server.
    /// Distinct from `signOut` — no logout HTTP call is made (the server already revoked
    /// everything) and it clears strictly more (SwiftData, receipt image files, all
    /// user-preference UserDefaults).
    ///
    /// `accountService` is passed in by the caller rather than held as a reference here
    /// so `AuthService` stays free of reverse dependencies on other services.
    func performFullAccountWipe(accountService: AccountService) async {
        // Best-effort: drop the APNs token server-side so the deleted account stops
        // being associated with this device. Swallow failures — the local wipe proceeds.
        if let pushService {
            await pushService.unregisterToken()
        }

        // 1. Server-side tokens are already revoked — just clear local Keychain.
        biometricService?.deleteLocalTokens()
        biometricService?.resetPromptFlag()

        // 2. SwiftData + receipt image files + selectedAccountId UserDefault.
        accountService.clearAllData()

        // 3. Offline identity.
        OfflineIdentity.clear()

        // 4. User-preference UserDefaults. Delete-account is "leave no trace".
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hasPromptedBiometricLogin")
        defaults.removeObject(forKey: AppConstants.Cleanup.imageRetentionKey)
        defaults.removeObject(forKey: "defaultEnhancementMode")
        defaults.removeObject(forKey: "lastOrphanCleanupDate")

        // 5. Session + user identity + authState. Last — flips root view to LoginView.
        clearSession()
        authState = .unauthenticated
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
            // Older server builds don't include mfa_methods — treat that as TOTP-only
            // (the pre-passkey default) so existing clients keep working.
            let methods = response.mfaMethods ?? MFAMethods(totp: true, webauthn: false)
            authState = .mfaRequired(mfaToken: mfaToken, methods: methods)
        } else if let sessionToken = response.sessionToken {
            apiClient.setSessionToken(sessionToken)
            // Login responses don't carry expires_at — assume the full lifetime.
            storeSessionExpiry(Date().addingTimeInterval(Self.sessionLifetime))
            saveUserInfo(response.user)
            loginAccounts = response.accounts
            loginProfile = response.user
            // Before flipping the state, so the gate is already up when the
            // main UI first renders instead of flashing in a beat later.
            applyTermsStatus(response.terms)
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

    /// The session is dead and silent recovery failed or isn't possible. Clears
    /// the stored token along with state — leaving a dead token in the Keychain
    /// makes every subsequent cold launch flash the authenticated UI, hit a 401,
    /// and bounce back to login.
    private func forceSignOut() {
        clearSession()
        authState = .unauthenticated
    }

    private func clearSession() {
        apiClient.clearSessionToken()
        // A retained accountId would ride along as X-Account-ID on the next
        // user's requests (AccountService only resets it via clearAllData,
        // which sign-out skips when an offline identity is kept).
        apiClient.accountId = nil
        clearSessionExpiry()
        currentUserId = nil
        currentUserEmail = nil
        loginAccounts = nil
        loginProfile = nil
        // The gate belongs to the user whose session carried the signal.
        termsStatus = nil
        UserDefaults.standard.removeObject(forKey: Self.userIdKey)
        UserDefaults.standard.removeObject(forKey: Self.userEmailKey)
    }
}

// MARK: - Account Deletion

enum DeleteAccountError: Error, LocalizedError {
    case invalidInput(message: String)          // 400
    case invalidPassword                         // 401
    case emailMismatch                           // 422
    case lastAdmin(message: String)              // 409 — user is sole admin on a multi-member account
    case alreadyScheduled                        // 409 — already soft-deleted
    case invalidResponse(message: String)        // 200 with malformed/unparseable body
    case network(Error)                          // URLError
    case server(status: Int, message: String?)  // 500, unexpected statuses, malformed bodies

    var errorDescription: String? {
        switch self {
        case .invalidInput(let m): m
        case .invalidPassword: "Incorrect password. Please try again."
        case .emailMismatch: "The email you entered doesn't match your account email."
        case .lastAdmin(let m): m
        case .alreadyScheduled: "Your account is already scheduled for deletion."
        case .invalidResponse(let m): m
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

struct WebAuthnBeginRequest: Encodable {
    let mfaToken: String

    enum CodingKeys: String, CodingKey {
        case mfaToken = "mfa_token"
    }
}

struct WebAuthnBeginResponse: Decodable {
    let options: PublicKeyCredentialRequestOptions
}

struct WebAuthnFinishRequest: Encodable {
    let mfaToken: String
    let assertion: PasskeyAssertionEnvelope

    enum CodingKeys: String, CodingKey {
        case assertion
        case mfaToken = "mfa_token"
    }
}

struct PasskeyBeginResponse: Decodable {
    let challengeToken: String
    let options: PublicKeyCredentialRequestOptions

    enum CodingKeys: String, CodingKey {
        case options
        case challengeToken = "challenge_token"
    }
}

struct PasskeyFinishRequest: Encodable {
    let challengeToken: String
    let assertion: PasskeyAssertionEnvelope

    enum CodingKeys: String, CodingKey {
        case assertion
        case challengeToken = "challenge_token"
    }
}

struct RefreshResponse: Decodable {
    let sessionToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
    }
}

struct LoginResponse: Decodable {
    let sessionToken: String?
    let mfaRequired: Bool?
    let mfaToken: String?
    let mfaMethods: MFAMethods?
    let user: LoginUser
    let accounts: [LoginAccount]?
    /// Present on every session-creating response; absent from the
    /// intermediate `mfa_required` response (no session yet) and from servers
    /// predating the terms contract.
    let terms: TermsStatus?

    enum CodingKeys: String, CodingKey {
        case user, accounts, terms
        case sessionToken = "session_token"
        case mfaRequired = "mfa_required"
        case mfaToken = "mfa_token"
        case mfaMethods = "mfa_methods"
    }
}

// MARK: - Terms DTOs

/// The terms re-acceptance signal, sent on every session-creating auth
/// response and on `GET /api/accounts`. The client keys off
/// `acceptanceRequired` **only** — never compare version strings client-side;
/// the server owns the comparison.
nonisolated struct TermsStatus: Decodable, Equatable, Sendable {
    let currentVersion: String
    /// `nil` for users who predate the signup clickwrap and have never
    /// accepted any version.
    let acceptedVersion: String?
    let acceptanceRequired: Bool
    let termsUrl: String
    let privacyUrl: String

    enum CodingKeys: String, CodingKey {
        case currentVersion = "current_version"
        case acceptedVersion = "accepted_version"
        case acceptanceRequired = "acceptance_required"
        case termsUrl = "terms_url"
        case privacyUrl = "privacy_url"
    }
}

extension TermsStatus {
    /// Builds a presentable status from the 403 backstop, which carries only
    /// the version and terms URL. Whatever a prior full signal knew fills the
    /// gaps; a fetch-time accounts refresh replaces this with the real thing.
    /// `@MainActor` because the fallback reads MainActor-isolated `AppConstants`
    /// (the type itself is nonisolated so nonisolated DTOs can decode it).
    @MainActor
    static func from403(_ payload: TermsRequiredPayload, merging existing: TermsStatus?) -> TermsStatus {
        TermsStatus(
            currentVersion: payload.termsVersion,
            acceptedVersion: existing?.acceptedVersion,
            acceptanceRequired: true,
            termsUrl: payload.termsUrl,
            privacyUrl: existing?.privacyUrl ?? AppConstants.Links.privacy.absoluteString
        )
    }
}

private struct TermsAcceptRequest: Encodable {
    let termsVersion: String
    enum CodingKeys: String, CodingKey { case termsVersion = "terms_version" }
}

private struct TermsAcceptResponse: Decodable {
    let terms: TermsStatus
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

nonisolated struct LoginAccount: Decodable {
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
