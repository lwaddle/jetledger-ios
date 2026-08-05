//
//  VerificationLink.swift
//  JetLedger
//
//  A tapped email-verification universal link, parsed and validated.
//
//  The verification link arrives in Mail, not in the app, so the in-app
//  SFSafariViewController from signup is long gone by the time the user taps
//  it. A universal link is the only mechanism that can route an https:// URL
//  back into an installed app — the app claims https://jetledger.io/verify-email/*
//  via the applinks block in the web app's AASA payload.
//
//  Validation is strict on purpose. This value is the sole gate between an
//  arbitrary inbound URL and a POST that mutates account state, and a loose
//  match would route the pages the app opens in SafariView (/signup, /terms,
//  /privacy, /forgot-password) into the verification sheet instead.
//

import Foundation

/// nonisolated, like `ServerDateFormatter`: a pure value type with no state,
/// parsed from a URL on the main actor but usable from anywhere.
nonisolated struct VerificationLink: Identifiable, Equatable {
    /// The raw token from the link's path — redeemed via
    /// `AuthService.verifyEmail(token:)`.
    let token: String

    /// The original URL, kept for the expired-link fallback: the web page at
    /// this address carries the real error copy and the resend affordance.
    let url: URL

    /// Identity keys the `.sheet(item:)` presentation, the same way `WebLink`'s
    /// does. Two taps on the same link are the same sheet.
    var id: String { token }

    /// Returns nil for anything that is not a verification link this app issued.
    init?(url: URL) {
        guard url.scheme == "https",
              let host = url.host(),
              host == AppConstants.Links.siteHost
        else { return nil }

        // ["/", "verify-email", "<token>"] — anything else is not our link.
        let components = url.pathComponents
        guard components.count == 3,
              components[1] == "verify-email",
              !components[2].isEmpty
        else { return nil }

        self.token = components[2]
        self.url = url
    }
}
