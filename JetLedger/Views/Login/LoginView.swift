//
//  LoginView.swift
//  JetLedger
//

import SwiftUI

struct LoginView: View {
    @Environment(AuthService.self) private var authService
    @Environment(NetworkMonitor.self) private var networkMonitor
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var isPasskeyLoading = false
    @State private var passkeyAutoAttempted = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 36)

            VStack(spacing: 16) {
                Button {
                    Task { await runPasskey() }
                } label: {
                    Group {
                        if isPasskeyLoading {
                            ProgressView()
                        } else {
                            Label("Sign in with passkey", systemImage: "key.fill")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(isPasskeyLoading || isLoading)

                HStack {
                    VStack { Divider() }
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack { Divider() }
                }

                TextField("Email", text: $email)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)

                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)

                if let error = authService.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                Button {
                    isLoading = true
                    Task {
                        await authService.signIn(email: email, password: password)
                        isLoading = false
                    }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Sign in with password")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(Color.accentColor)
                .disabled(email.isEmpty || password.isEmpty || isLoading || isPasskeyLoading)

                Text("Forgot password? Reset at jetledger.io")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 32)

            // Continue offline option
            if let identity = OfflineIdentity.load() {
                VStack(spacing: 6) {
                    if !networkMonitor.isConnected {
                        Text("No connection?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        authService.enterOfflineMode()
                    } label: {
                        Text("Continue offline as \(identity.email)")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
            Spacer()
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            if let identity = OfflineIdentity.load() {
                email = identity.email
            }
        }
        .task {
            // Auto-fire the OS passkey sheet on first appearance so a user with an
            // iCloud-synced passkey can sign in with just Face ID. Only once per
            // view lifetime — a cancelled prompt shouldn't re-fire while the user
            // is typing. Skipped if the network is down (ceremony needs the server).
            guard !passkeyAutoAttempted, networkMonitor.isConnected else { return }
            passkeyAutoAttempted = true
            await runPasskey()
        }
    }

    private func runPasskey() async {
        isPasskeyLoading = true
        defer { isPasskeyLoading = false }
        do {
            try await authService.signInWithPasskey()
        } catch PasskeyError.cancelled {
            // User dismissed the sheet. No error banner — they can use the
            // password form or tap the passkey button again.
        } catch {
            // Non-cancel errors already populated authService.errorMessage.
        }
    }
}
