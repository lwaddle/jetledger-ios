//
//  MFAEnrollmentRequiredView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/24/26.
//

import SwiftUI

struct MFAEnrollmentRequiredView: View {
    @Environment(AuthService.self) private var authService
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Two-Factor Authentication Required")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text("Your organization requires two-factor authentication. Please set up MFA using the JetLedger web app, then sign in here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 16) {
                if let error = authService.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                Link(destination: AppConstants.Links.webApp) {
                    Text("Open Web App")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)

                Button {
                    isLoading = true
                    Task {
                        await authService.retryAfterMFAEnrollment()
                        isLoading = false
                    }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Try Again")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)

                Button("Sign Out") {
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
