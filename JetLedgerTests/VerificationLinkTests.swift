//
//  VerificationLinkTests.swift
//  JetLedgerTests
//
//  The parser stands between a tapped universal link and a POST that mutates
//  account state, so it is the one piece of this feature worth testing without
//  a device. A too-loose match would let any jetledger.io link open the
//  verification sheet; a too-tight one silently drops real verifications back
//  to "nothing happened" when the app opens.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
struct VerificationLinkTests {

    @Test
    func parsesTokenFromACanonicalVerifyLink() {
        let link = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123XYZ")!)
        #expect(link?.token == "abc123XYZ")
    }

    @Test
    func keepsTheOriginalURLForTheBrowserFallback() {
        let url = URL(string: "https://jetledger.io/verify-email/abc123XYZ")!
        #expect(VerificationLink(url: url)?.url == url)
    }

    @Test
    func rejectsAnotherHost() {
        #expect(VerificationLink(url: URL(string: "https://evil.example.com/verify-email/abc123")!) == nil)
    }

    @Test
    func rejectsPlainHTTP() {
        #expect(VerificationLink(url: URL(string: "http://jetledger.io/verify-email/abc123")!) == nil)
    }

    /// The other jetledger.io pages the app links to must never route through
    /// the verification sheet — they open in SafariView.
    @Test
    func rejectsTheInAppBrowserPages() {
        #expect(VerificationLink(url: AppConstants.Links.signup) == nil)
        #expect(VerificationLink(url: AppConstants.Links.terms) == nil)
        #expect(VerificationLink(url: AppConstants.Links.privacy) == nil)
        #expect(VerificationLink(url: AppConstants.Links.forgotPassword) == nil)
    }

    @Test
    func rejectsAMissingToken() {
        #expect(VerificationLink(url: URL(string: "https://jetledger.io/verify-email/")!) == nil)
        #expect(VerificationLink(url: URL(string: "https://jetledger.io/verify-email")!) == nil)
    }

    /// A trailing segment means the link is not the one we issued; redeeming
    /// the middle segment would be guessing.
    @Test
    func rejectsExtraPathSegments() {
        #expect(VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123/extra")!) == nil)
    }

    @Test
    func identityFollowsTheToken() {
        let a = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123")!)
        let b = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123")!)
        let c = VerificationLink(url: URL(string: "https://jetledger.io/verify-email/different")!)
        #expect(a?.id == b?.id)
        #expect(a?.id != c?.id)
    }

    @Test
    func verifyEndpointResolvesToItsPublishedRoute() {
        #expect(AppConstants.WebAPI.authVerifyEmail == "/api/auth/verify-email")
    }

    @Test
    func siteHostIsDerivedFromTheCanonicalSiteURL() {
        #expect(AppConstants.Links.siteHost == "jetledger.io")
    }
}

/// The status→outcome mapping is the whole decision this feature makes on a
/// server response, and it is worth pinning independently of the network:
/// a 400 that means "your link is dead" and a 400 that means "the app sent a
/// malformed request" must never show the same thing to the user.
///
/// Each test is `@MainActor` because `AuthService` is — the same convention
/// `TermsContractTests` uses for tests that touch MainActor-isolated types.
@Suite
struct EmailVerificationOutcomeTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test
    @MainActor
    func successVerifies() {
        let outcome = AuthService.verificationOutcome(status: 200, data: body(#"{"verified":true}"#))
        #expect(outcome == .verified)
    }

    @Test
    @MainActor
    func deadTokenIsInvalidOrExpired() {
        let outcome = AuthService.verificationOutcome(status: 400, data: body(#"{"error":"invalid_or_expired"}"#))
        #expect(outcome == .invalidOrExpired)
    }

    /// A client-side bug must not be reported to the user as an expired link.
    @Test
    @MainActor
    func malformedRequestIsNotReportedAsAnExpiredLink() {
        let outcome = AuthService.verificationOutcome(status: 400, data: body(#"{"error":"invalid_request"}"#))
        #expect(outcome != .invalidOrExpired)
        if case .failed = outcome {} else {
            Issue.record("invalid_request should map to .failed, got \(outcome)")
        }
    }

    /// Matched exactly, like the terms 403 backstop — a substring match would
    /// let an unrelated error containing the phrase read as a dead link.
    @Test
    @MainActor
    func unrecognizedFourHundredIsNotInvalidOrExpired() {
        let outcome = AuthService.verificationOutcome(status: 400, data: body(#"{"error":"invalid_or_expired_something_else"}"#))
        #expect(outcome != .invalidOrExpired)
    }

    @Test
    @MainActor
    func serverErrorSurfacesTheServerMessage() {
        let outcome = AuthService.verificationOutcome(status: 500, data: body(#"{"error":"internal"}"#))
        #expect(outcome == .failed(message: "internal"))
    }

    @Test
    @MainActor
    func unreadableBodyStillFailsCleanly() {
        let outcome = AuthService.verificationOutcome(status: 503, data: body("<html>gateway</html>"))
        if case .failed = outcome {} else {
            Issue.record("an unreadable body should still map to .failed, got \(outcome)")
        }
    }
}
