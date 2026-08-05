//
//  EmailVerificationView.swift
//  JetLedger
//
//  Shown when the user taps their email-verification link and iOS routes it
//  here as a universal link. It redeems the token natively rather than opening
//  the web page: the point of claiming the link at all is that the user stops
//  being handed to Safari at the one moment they are least oriented.
//
//  The expired state does open the web page — in the in-app SafariView — because
//  that page already carries the real error copy and the resend affordance, and
//  a native dead end would be worse than a browser that stays inside the app.
//
//  Transport failure is deliberately a separate state from expired. Telling
//  someone on a bad connection that their link is dead sends them looking for a
//  new email that will never help.
//

import SwiftUI

struct EmailVerificationView: View {
    let link: VerificationLink

    @Environment(AuthService.self) private var authService
    @Environment(RootSheetRouter.self) private var sheetRouter
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case verifying
        case verified
        case expired
        case failed(message: String)
    }

    @State private var phase: Phase = .verifying

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            switch phase {
            case .verifying:
                ProgressView()
                    .controlSize(.large)
                Text("Verifying your email…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .verified:
                icon("checkmark.circle.fill", color: Color(.statusSuccess))
                headline("Email verified", detail: "You're all set. You can sign in now.")

            case .expired:
                icon("exclamationmark.triangle.fill", color: Color(.statusWarning))
                headline(
                    "Link expired",
                    detail: "This verification link has expired or was already used."
                )

            case .failed(let message):
                icon("exclamationmark.triangle.fill", color: Color(.statusError))
                headline("Couldn't verify", detail: message)
            }

            Spacer()

            actions
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            phase = await verify()
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            switch phase {
            case .verifying:
                EmptyView()

            case .verified:
                primaryButton("Continue") { dismiss() }

            case .expired:
                // The web page owns the real error copy and the resend path.
                // Routed rather than stacked: this replaces the verification
                // sheet with the browser instead of layering a second sheet
                // over it, so the user closes one thing, not two.
                primaryButton("Open in browser") {
                    sheetRouter.show(.web(WebLink(link.url)))
                }
                Button("Dismiss") { dismiss() }

            case .failed:
                primaryButton("Try Again") {
                    phase = .verifying
                    Task { phase = await verify() }
                }
                Button("Dismiss") { dismiss() }
            }
        }
    }

    private func verify() async -> Phase {
        switch await authService.verifyEmail(token: link.token) {
        case .verified:
            return .verified
        case .invalidOrExpired:
            return .expired
        case .failed(let message):
            return .failed(message: message)
        }
    }

    // MARK: - Pieces

    private func icon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 44))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func headline(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title2.bold())
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(.brandPrimary))
    }
}
