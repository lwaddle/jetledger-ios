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
