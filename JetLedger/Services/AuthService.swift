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
            authState = .authenticated
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
                authState = .authenticated
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
        try await supabase.auth.resetPasswordForEmail(
            email,
            redirectTo: URL(string: "jetledger://reset-password")
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

            // Ensure we're on the login screen (handles cold launch with stale session)
            authState = .unauthenticated
            isExchangingResetCode = false
            // Set LAST so .onChange sees passwordResetMFAFactorId already populated
            isPasswordResetActive = true
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
        try await supabase.auth.signOut(scope: .local)
        authState = .unauthenticated
    }

    private func schedulePasswordResetTimeout() {
        passwordResetTimeoutTask?.cancel()
        passwordResetTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(15 * 60))
            guard !Task.isCancelled, isPasswordResetActive else { return }
            await cancelPasswordReset()
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
