//
//  LoginView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct LoginView: View {
    @Environment(AuthService.self) private var authService
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var showPasswordReset = false

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

                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                    .textContentType(.password)

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
                            Text("Sign In")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                Button("Forgot Password?") {
                    showPasswordReset = true
                }
                .foregroundStyle(.secondary)
                .font(.callout)
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
        .sheet(isPresented: $showPasswordReset) {
            PasswordResetView()
        }
        .onAppear {
            if authService.isPasswordResetActive {
                showPasswordReset = true
            }
        }
        .onChange(of: authService.isPasswordResetActive) { _, isActive in
            if isActive {
                showPasswordReset = true
            }
        }
    }
}
