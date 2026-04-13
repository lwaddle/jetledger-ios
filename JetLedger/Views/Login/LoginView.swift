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
                    focusedField = nil
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
                            Text("Sign In")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(email.isEmpty || password.isEmpty || isLoading)

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
    }
}
