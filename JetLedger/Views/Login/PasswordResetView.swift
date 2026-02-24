//
//  PasswordResetView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/16/26.
//

import SwiftUI

struct PasswordResetView: View {
    @Environment(AuthService.self) private var authService
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .email
    @State private var email = ""
    @State private var mfaCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isLoading = false

    private enum Step {
        case email, linkSent, mfaVerify, newPassword
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                switch step {
                case .email:
                    emailStep
                case .linkSent:
                    linkSentStep
                case .mfaVerify:
                    mfaVerifyStep
                case .newPassword:
                    newPasswordStep
                }

                Spacer()
                Spacer()
            }
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelReset() }
                }
            }
            .onChange(of: authService.isPasswordResetActive) { _, isActive in
                if isActive {
                    errorMessage = nil
                    if authService.passwordResetMFAFactorId != nil {
                        step = .mfaVerify
                    } else {
                        step = .newPassword
                    }
                }
            }
        }
    }

    // MARK: - Step 1: Email

    private var emailStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Enter your email address and we'll send you a link to reset your password.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Email", text: $email)
                .textFieldStyle(.plain)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            errorLabel

            Button {
                sendResetLink()
            } label: {
                loadingButtonLabel("Send Reset Link")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(email.isEmpty || isLoading)
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    // MARK: - Step 2: Link Sent

    private var linkSentStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Check your email")
                .font(.title3)
                .fontWeight(.semibold)

            Text("We sent a password reset link to **\(email)**. Tap the link in the email to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            errorLabel

            Button {
                if let mailURL = URL(string: "message://"), UIApplication.shared.canOpenURL(mailURL) {
                    UIApplication.shared.open(mailURL)
                }
            } label: {
                Label("Open Mail", systemImage: "envelope")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)

            Button("Resend link") {
                sendResetLink()
            }
            .foregroundStyle(.secondary)
            .disabled(isLoading)
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    // MARK: - Step 3: MFA Verify

    private var mfaVerifyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Verify your identity")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Enter the 6-digit code from your authenticator app to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("000000", text: $mfaCode)
                .textFieldStyle(.plain)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2.monospaced())
                .onChange(of: mfaCode) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue {
                        mfaCode = filtered
                    }
                }

            errorLabel

            Button {
                verifyMFA()
            } label: {
                loadingButtonLabel("Verify")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(mfaCode.count != 6 || isLoading)
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    // MARK: - Step 4: New Password

    private var newPasswordStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.rotation")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Choose a new password")
                .font(.title3)
                .fontWeight(.semibold)

            SecureField("New password", text: $newPassword)
                .textFieldStyle(.plain)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .textContentType(.newPassword)

            SecureField("Confirm password", text: $confirmPassword)
                .textFieldStyle(.plain)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                .textContentType(.newPassword)

            errorLabel

            Button {
                resetPassword()
            } label: {
                loadingButtonLabel("Reset Password")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(newPassword.isEmpty || confirmPassword.isEmpty || isLoading)
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 32)
    }

    // MARK: - Shared Components

    @ViewBuilder
    private var errorLabel: some View {
        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
    }

    private func loadingButtonLabel(_ title: String) -> some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func cancelReset() {
        if authService.isPasswordResetActive {
            Task { await authService.cancelPasswordReset() }
        }
        dismiss()
    }

    private func sendResetLink() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await authService.resetPasswordForEmail(email)
                step = .linkSent
            } catch is URLError {
                errorMessage = "Unable to connect. Check your internet connection and try again."
            } catch {
                errorMessage = "Failed to send reset link. Please try again."
            }
            isLoading = false
        }
    }

    private func verifyMFA() {
        guard let factorId = authService.passwordResetMFAFactorId else { return }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await authService.verifyMFAForPasswordReset(code: mfaCode, factorId: factorId)
                step = .newPassword
            } catch {
                errorMessage = "Invalid code. Please try again."
            }
            isLoading = false
        }
    }

    private func resetPassword() {
        guard newPassword == confirmPassword else {
            errorMessage = "Passwords don't match."
            return
        }
        guard newPassword.count >= 8 else {
            errorMessage = "Password must be at least 8 characters."
            return
        }
        guard newPassword.range(of: "[A-Z]", options: .regularExpression) != nil else {
            errorMessage = "Password must contain at least one uppercase letter."
            return
        }
        guard newPassword.range(of: "[0-9]", options: .regularExpression) != nil else {
            errorMessage = "Password must contain at least one number."
            return
        }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await authService.updatePassword(newPassword)
                dismiss()
            } catch {
                errorMessage = "Failed to reset password: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}
