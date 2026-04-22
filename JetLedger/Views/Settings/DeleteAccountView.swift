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
    @State private var inFlight = false

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

    private var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    private var isSuccess: Bool {
        if case .success = phase { return true }
        return false
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
                // No cancel on success — user must tap Done.
                if !isSuccess {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                            .disabled(isSubmitting)
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
                Task {
                    await authService.performFullAccountWipe(accountService: accountService)
                    dismiss()
                }
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
        guard !inFlight else { return }
        inFlight = true
        error = nil
        let notifier = UINotificationFeedbackGenerator()
        notifier.notificationOccurred(.warning)
        phase = .submitting
        Task {
            defer { inFlight = false }
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
