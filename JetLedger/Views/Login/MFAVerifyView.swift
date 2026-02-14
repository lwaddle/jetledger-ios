//
//  MFAVerifyView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct MFAVerifyView: View {
    @Environment(AuthService.self) private var authService
    let factorId: String

    @State private var code = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Two-Factor Authentication")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the 6-digit code from your authenticator app")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 16) {
                TextField("000000", text: $code)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospaced())
                    .onChange(of: code) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue {
                            code = filtered
                        }
                    }

                if let error = authService.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                Button {
                    isLoading = true
                    Task {
                        await authService.verifyMFA(code: code, factorId: factorId)
                        isLoading = false
                    }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Verify")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(code.count != 6 || isLoading)

                Button("Use a different account") {
                    Task { await authService.signOut() }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 400)
            .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }
}
