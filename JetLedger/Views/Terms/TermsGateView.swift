//
//  TermsGateView.swift
//  JetLedger
//
//  Blocking gate shown when a live server response says the user must accept
//  the current Terms of Service (`acceptance_required: true` on the terms
//  signal, or the typed 403 backstop). Rendered as an opaque layer *over*
//  MainView rather than replacing it, so services and in-progress UI survive:
//  a capture sheet that was already open can finish (its upload parks on the
//  server's 403 and retries after acceptance), and nothing is torn down for a
//  condition one tap resolves. Only fresh server responses raise it — a
//  transport error never does, so it can never block offline capture.
//
//  The document itself is shown via `terms_url` in the SafariView pattern —
//  there is no content API. Declining stays possible the same way the web
//  gate keeps it possible: sign out, or delete the account (both server
//  endpoints are allowlisted past the 403 backstop).
//

import SwiftUI

struct TermsGateView: View {
    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService

    @State private var webLink: WebLink?
    @State private var isAccepting = false
    @State private var errorMessage: String?
    @State private var versionChanged = false
    @State private var showDeleteAccount = false

    private var status: TermsStatus? { authService.termsStatus }

    /// Users who predate the signup clickwrap (`accepted_version: null`) have
    /// never accepted any version — for them this is a first acceptance, not
    /// an update, and the copy shouldn't claim otherwise.
    private var isFirstAcceptance: Bool { status?.acceptedVersion == nil }

    /// Server-sent URLs, so a moved page doesn't need an app update; the
    /// constants are the fallback if a URL string ever fails to parse.
    private var termsURL: URL {
        status.flatMap { URL(string: $0.termsUrl) } ?? AppConstants.Links.terms
    }

    private var privacyURL: URL {
        status.flatMap { URL(string: $0.privacyUrl) } ?? AppConstants.Links.privacy
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // doc.plaintext, not the iOS 18-renamed text.document — the
            // deployment target is 17.6.
            Image(systemName: "doc.plaintext")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(isFirstAcceptance ? "Terms of Service" : "Updated Terms of Service")
                    .font(.title2.bold())

                Text(isFirstAcceptance
                     ? "Please review and accept the JetLedger Terms of Service to continue."
                     : "The JetLedger Terms of Service have changed since you last accepted them. Please review and accept the updated Terms to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let version = status?.currentVersion {
                    Text("Terms version \(version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)

            if versionChanged {
                notice(
                    "The Terms were updated again just now. Please review the latest version before agreeing.",
                    color: Color(.statusWarning),
                    textColor: Color(.statusWarningContent)
                )
            } else if let errorMessage {
                notice(errorMessage, color: Color(.statusError), textColor: Color(.statusError))
            }

            VStack(spacing: 12) {
                Button {
                    webLink = WebLink(termsURL)
                } label: {
                    Label("Review Terms of Service", systemImage: "safari")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(Color.accentColor)

                Button {
                    Task { await accept() }
                } label: {
                    Group {
                        if isAccepting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("I Agree")
                        }
                    }
                    .foregroundStyle(.white)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                // BrandPrimary, not the accent: filled surfaces under white
                // text use the navy primary (two-token rule).
                .buttonStyle(.borderedProminent)
                .tint(Color(.brandPrimary))
                .disabled(isAccepting)

                Button("Privacy Policy") {
                    webLink = WebLink(privacyURL)
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 24)

            Spacer()

            // The decline paths. Sign-out keeps the offline identity — locally
            // captured receipts stay on the device and upload after a future
            // sign-in (which re-presents this gate). Deletion is the web
            // gate's parity path; the endpoint is allowlisted past the 403.
            VStack(spacing: 12) {
                Button("Sign Out") {
                    Task { await signOut() }
                }
                .font(.subheadline)

                Button("Delete Account", role: .destructive) {
                    showDeleteAccount = true
                }
                .font(.footnote)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .safariSheet($webLink)
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountView()
        }
    }

    private func notice(_ text: String, color: Color, textColor: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)
    }

    private func accept() async {
        guard !isAccepting else { return }
        isAccepting = true
        errorMessage = nil
        versionChanged = false
        defer { isAccepting = false }

        switch await authService.acceptCurrentTerms() {
        case .accepted:
            break // termsAcceptanceRequired flips false; the gate unmounts.
        case .versionChanged:
            versionChanged = true
        case .failed(let message):
            errorMessage = message
        }
    }

    /// Mirrors SettingsView's sign-out: save the offline identity first so
    /// queued captures survive on-device, then end the session.
    private func signOut() async {
        if let account = accountService.selectedAccount,
           let userId = authService.currentUserId {
            let identity = OfflineIdentity(
                userId: userId,
                email: accountService.userProfile?.email ?? authService.currentUserEmail ?? "",
                accountId: account.id,
                accountName: account.name,
                role: account.role
            )
            OfflineIdentity.save(identity)
        }
        await authService.signOutRetainingIdentity()
    }
}
