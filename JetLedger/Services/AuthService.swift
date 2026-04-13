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
