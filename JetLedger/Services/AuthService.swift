//
//  AuthService.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Auth
import Foundation
import Observation
import Supabase

@Observable
class AuthService {
    var authState: AuthState = .loading
    var errorMessage: String?
    var isPasswordResetActive = false
    var passwordResetMFAFactorId: String?
    var passwordResetEmail: String?
    private var isExchangingResetCode = false
    private var passwordResetTimeoutTask: Task<Void, Never>?

    let supabase: SupabaseClient

    init() {
        supabase = SupabaseClient(
            supabaseURL: AppConstants.Supabase.url,
            supabaseKey: AppConstants.Supabase.anonKey,
            options: .init(auth: .init(emitLocalSessionAsInitialSession: true))
        )
        Task { await listenForAuthChanges() }
    }

    var currentUserId: UUID? {
        supabase.auth.currentSession?.user.id
    }

    // MARK: - Auth State Listener

    private func listenForAuthChanges() async {
        for await (event, _) in supabase.auth.authStateChanges {
            // Don't let auth events interfere with the password reset flow.
            // The recovery session is managed directly by handlePasswordResetDeepLink.
            if isPasswordResetActive || isExchangingResetCode { continue }

            switch event {
            case .initialSession:
                if let session = supabase.auth.currentSession {
                    await handleExistingSession(session)
                } else {
                    authState = .unauthenticated
                }
            case .signedOut:
                if authState == .offlineReady { break }
                authState = .unauthenticated
            default:
                break
            }
        }
    }

    private func handleExistingSession(_ session: Session) async {
        let verifiedTOTP = session.user.factors?.filter {
            $0.factorType == "totp" && $0.status == .verified
        } ?? []

        guard !verifiedTOTP.isEmpty else {
            // No TOTP enrolled — check if the account requires MFA
            if await checkMFARequired(userId: session.user.id) {
                authState = .mfaEnrollmentRequired
            } else {
                authState = .authenticated
            }
            return
        }

        // User has TOTP enrolled — check if session is already AAL2
        do {
            let aal = try await supabase.auth.mfa.getAuthenticatorAssuranceLevel()
            if aal.currentLevel == "aal1", aal.nextLevel == "aal2" {
                if let factor = verifiedTOTP.first {
                    authState = .mfaRequired(factorId: factor.id)
                }
            } else {
                authState = .authenticated
            }
        } catch {
            // If AAL check fails, assume authenticated
            authState = .authenticated
        }
    }

    // MARK: - Sign In

    func signIn(email: String, password: String) async {
        errorMessage = nil
        do {
            let session = try await supabase.auth.signIn(
                email: email, password: password
            )

            let verifiedTOTP = session.user.factors?.filter {
                $0.factorType == "totp" && $0.status == .verified
            } ?? []

            if let factor = verifiedTOTP.first {
                authState = .mfaRequired(factorId: factor.id)
            } else {
                // No TOTP enrolled — check if the account requires MFA
                if await checkMFARequired(userId: session.user.id) {
                    authState = .mfaEnrollmentRequired
                } else {
                    authState = .authenticated
                }
            }
        } catch {
            errorMessage = mapAuthError(error)
        }
    }

    // MARK: - MFA

    func verifyMFA(code: String, factorId: String) async {
        errorMessage = nil
        do {
            try await supabase.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(
                    factorId: factorId, code: code
                )
            )
            authState = .authenticated
        } catch {
            errorMessage = "Invalid code. Please try again."
        }
    }

    // MARK: - Password Reset

    func resetPasswordForEmail(_ email: String) async throws {
        let redirectURL = AppConstants.Links.webApp.appendingPathComponent("auth/ios-callback")
        try await supabase.auth.resetPasswordForEmail(
            email,
            redirectTo: redirectURL
        )
    }

    func handlePasswordResetDeepLink(url: URL) async throws {
        // Guard the listener during the exchange so the recovery session
        // doesn't trigger MFAVerifyView or authenticated state.
        isExchangingResetCode = true

        do {
            let session = try await supabase.auth.session(from: url)

            let verifiedTOTP = session.user.factors?.filter {
                $0.factorType == "totp" && $0.status == .verified
            } ?? []

            if let factor = verifiedTOTP.first {
                passwordResetMFAFactorId = factor.id
            }

            passwordResetEmail = session.user.email
            // Set isPasswordResetActive BEFORE changing authState so the listener
            // guard is up before any view recreation triggered by state change.
            isPasswordResetActive = true
            authState = .unauthenticated
            isExchangingResetCode = false
            schedulePasswordResetTimeout()
        } catch {
            isExchangingResetCode = false
            throw error
        }
    }

    func verifyMFAForPasswordReset(code: String, factorId: String) async throws {
        try await supabase.auth.mfa.challengeAndVerify(
            params: MFAChallengeAndVerifyParams(
                factorId: factorId, code: code
            )
        )
        passwordResetMFAFactorId = nil
    }

    func cancelPasswordReset() async {
        passwordResetTimeoutTask?.cancel()
        passwordResetTimeoutTask = nil
        isPasswordResetActive = false
        passwordResetMFAFactorId = nil
        passwordResetEmail = nil
        // Clear the recovery session so it doesn't interfere on next launch
        if supabase.auth.currentSession != nil {
            try? await supabase.auth.signOut(scope: .local)
        }
        authState = .unauthenticated
    }

    func updatePassword(_ newPassword: String) async throws {
        try await supabase.auth.update(user: UserAttributes(password: newPassword))
        passwordResetTimeoutTask?.cancel()
        passwordResetTimeoutTask = nil
        isPasswordResetActive = false
        passwordResetMFAFactorId = nil
        passwordResetEmail = nil
        // Keep the session from the PKCE exchange — user is already authenticated
        authState = .authenticated
    }

    private func schedulePasswordResetTimeout() {
        passwordResetTimeoutTask?.cancel()
        passwordResetTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(15 * 60))
            guard !Task.isCancelled, isPasswordResetActive else { return }
            await cancelPasswordReset()
        }
    }

    // MARK: - MFA Enrollment Check

    private func checkMFARequired(userId: UUID) async -> Bool {
        do {
            let result: Bool = try await supabase
                .rpc("user_requires_mfa", params: ["_user_id": userId])
                .execute()
                .value
            return result
        } catch {
            // If the check fails, don't block access
            return false
        }
    }

    func retryAfterMFAEnrollment() async {
        errorMessage = nil
        do {
            let session = try await supabase.auth.refreshSession()

            let verifiedTOTP = session.user.factors?.filter {
                $0.factorType == "totp" && $0.status == .verified
            } ?? []

            if let factor = verifiedTOTP.first {
                // User enrolled MFA on web — proceed to verification
                authState = .mfaRequired(factorId: factor.id)
            } else {
                errorMessage = "MFA has not been set up yet. Please complete setup in the web app first."
            }
        } catch {
            errorMessage = "Unable to check MFA status. Please try again."
        }
    }

    // MARK: - Sign Out

    func signOut() async {
        do {
            try await supabase.auth.signOut(scope: .local)
        } catch {
            // Clear local state even if server sign-out fails
        }
        authState = .unauthenticated
        errorMessage = nil
    }

    func signOutRetainingIdentity() async {
        do {
            try await supabase.auth.signOut(scope: .local)
        } catch {
            // Clear local state even if server sign-out fails
        }
        authState = .offlineReady
        errorMessage = nil
    }

    func enterOfflineMode() {
        guard OfflineIdentity.load() != nil else { return }
        authState = .offlineReady
    }

    // MARK: - Error Mapping

    private func mapAuthError(_ error: Error) -> String {
        let description = "\(error)"
        if description.contains("Invalid login credentials") {
            return "Invalid email or password."
        }
        if description.contains("Email not confirmed") {
            return "Please verify your email address before signing in."
        }
        if error is URLError {
            return "Unable to connect. Check your internet connection and try again."
        }
        return "Something went wrong. Please try again."
    }
}
