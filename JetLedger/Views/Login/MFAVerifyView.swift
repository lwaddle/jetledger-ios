//
//  MFAVerifyView.swift
//  JetLedger
//

import SwiftUI

struct MFAVerifyView: View {
    @Environment(AuthService.self) private var authService
    let mfaToken: String
    let methods: MFAMethods

    @State private var code = ""
    @State private var recoveryCode = ""
    @State private var isLoading = false
    @State private var hasAutoSubmitted = false
    @State private var useRecoveryCode = false
    @State private var passkeyAutoAttempted = false
    @FocusState private var codeIsFocused: Bool
    @FocusState private var recoveryIsFocused: Bool

    private var showTOTPSection: Bool { methods.totp }
    private var showPasskeySection: Bool { methods.webauthn }

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
            } else if showPasskeySection && !showTOTPSection {
                passkeyOnlySection
            } else if showPasskeySection && showTOTPSection {
                passkeyWithTOTPFallbackSection
            } else {
                totpCodeSection
            }

            Spacer()
            Spacer()
        }
        .task {
            // Passkey-capable users get the OS prompt automatically — once.
            if showPasskeySection && !passkeyAutoAttempted && !useRecoveryCode {
                passkeyAutoAttempted = true
                await runPasskey()
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            if useRecoveryCode {
                recoveryIsFocused = true
            } else if showTOTPSection {
                codeIsFocused = true
            }
        }
    }

    // MARK: - Passkey-first sections

    /// Shown when passkeys are the user's only 2FA method (no TOTP). The system
    /// dialog fires in `.task` above; this view only exists to let the user retry
    /// or sign out if they cancel.
    private var passkeyOnlySection: some View {
        VStack(spacing: 16) {
            Text("Use your passkey to sign in")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            errorMessageView

            Button {
                Task { await runPasskey() }
            } label: {
                Label("Sign in with passkey", systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(isLoading)

            signOutButton
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    /// Passkey is primary. A one-tap fallback switches into the TOTP section
    /// if the user prefers their authenticator app (or the passkey prompt failed).
    private var passkeyWithTOTPFallbackSection: some View {
        VStack(spacing: 16) {
            Text("Use your passkey to sign in, or fall back to your authenticator app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            errorMessageView

            Button {
                Task { await runPasskey() }
            } label: {
                Label("Sign in with passkey", systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(isLoading)

            Button("Use authenticator app instead") {
                // Flip the flag so the task gate doesn't re-auto-prompt, then show TOTP.
                passkeyAutoAttempted = true
                // Re-render into the plain TOTP section by clearing the passkey flag
                // locally via a swap to the TOTP variant. We model that by reusing
                // the same view but hiding the passkey button: simplest is to present
                // the TOTP UI inline.
                useAuthenticatorFallback = true
                codeIsFocused = true
            }
            .foregroundStyle(.secondary)
            .font(.callout)

            // Inline TOTP entry when the user chooses to switch methods.
            if useAuthenticatorFallback {
                Divider().padding(.vertical, 8)
                totpCodeSection
            } else {
                signOutButton
            }
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    @State private var useAuthenticatorFallback = false

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

    private func runPasskey() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.verifyMFAWithPasskey(mfaToken: mfaToken)
        } catch PasskeyError.cancelled {
            // User dismissed the OS passkey sheet. Don't show an error — silently
            // reveal the TOTP/sign-out options so they can pick another path.
            if showTOTPSection {
                useAuthenticatorFallback = true
                codeIsFocused = true
            }
        } catch {
            // Error message is already set by AuthService for non-cancel errors.
        }
    }

    private func submitTOTP(_ totpCode: String) {
        isLoading = true
        Task {
            await authService.verifyMFA(code: totpCode, mfaToken: mfaToken)
            isLoading = false
            if authService.errorMessage != nil {
                code = ""
                hasAutoSubmitted = false
                codeIsFocused = true
            } else {
                codeIsFocused = false
            }
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
            if authService.errorMessage == nil {
                recoveryIsFocused = false
            }
        }
    }
}
