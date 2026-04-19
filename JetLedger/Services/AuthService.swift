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

    /// Optional — injected by JetLedgerApp. Nil on devices that don't advertise
    /// Associated Domains or in test harnesses that don't need passkey support.
    var passkeyService: PasskeyAuthService?

    private static let userIdKey = "currentUserId"
    private static let userEmailKey = "currentUserEmail"

    init() {
        apiClient = APIClient(baseURL: AppConstants.WebAPI.baseURL)
        apiClient.onUnauthorized = { [weak self] in
            guard let self else { return }
            switch self.authState {
            case .authenticated, .offlineReady:
                // Try biometric re-auth before kicking to login screen.
                // Guard prevents concurrent 401s from spawning multiple Face ID prompts.
                if let bioService = self.biometricService,
                   bioService.isBiometricLoginEnabled,
                   !self.isReauthenticating {
                    self.isReauthenticating = true
                    Task {
                        defer { self.isReauthenticating = false }
                        if let response = await bioService.attemptBiometricLogin(apiClient: self.apiClient) {
                            self.handleLoginResponse(response)
                        } else {
                            self.authState = .unauthenticated
                        }
                    }
                } else if !self.isReauthenticating {
                    self.authState = .unauthenticated
                }
            default:
                break // Don't redirect during login/MFA flow
            }
        }
        // Restore cached user info for OfflineIdentity comparison
        currentUserId = UserDefaults.standard.string(forKey: Self.userIdKey).flatMap(UUID.init)
        currentUserEmail = UserDefaults.standard.string(forKey: Self.userEmailKey)
    }

    /// Set by JetLedgerApp after creating BiometricAuthService.
    var biometricService: BiometricAuthService?
    private var isReauthenticating = false

    // MARK: - Session Restore

    func restoreSession() async {
        if apiClient.sessionToken != nil {
            authState = .authenticated
        } else if let bioService = biometricService, bioService.isBiometricLoginEnabled {
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
            // Older server builds don't include mfa_methods — treat that as TOTP-only
            // (the pre-passkey default) so existing clients keep working.
            let methods = response.mfaMethods ?? MFAMethods(totp: true, webauthn: false)
            authState = .mfaRequired(mfaToken: mfaToken, methods: methods)
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

struct LoginResponse: Decodable {
    let sessionToken: String?
    let mfaRequired: Bool?
    let mfaToken: String?
    let mfaMethods: MFAMethods?
    let user: LoginUser
    let accounts: [LoginAccount]?

    enum CodingKeys: String, CodingKey {
        case user, accounts
        case sessionToken = "session_token"
        case mfaRequired = "mfa_required"
        case mfaToken = "mfa_token"
        case mfaMethods = "mfa_methods"
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
