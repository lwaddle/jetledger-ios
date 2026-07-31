//
//  LegalLinksTests.swift
//  JetLedgerTests
//
//  The failure mode these guard is a typo'd path shipping as a 404 on a page an
//  App Store reviewer opens. The paths must match the web app's routes
//  (`docs/routes.md` in the jetledger repo); nothing in the app fetches them, so
//  a wrong one is invisible until someone taps it.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
struct LegalLinksTests {

    @Test
    func legalPagesResolveToTheirPublishedRoutes() {
        #expect(AppConstants.Links.privacy.absoluteString == "https://jetledger.io/privacy")
        #expect(AppConstants.Links.terms.absoluteString == "https://jetledger.io/terms")
    }

    @Test
    func accountPagesResolveToTheirPublishedRoutes() {
        #expect(AppConstants.Links.signup.absoluteString == "https://jetledger.io/signup")
        #expect(AppConstants.Links.forgotPassword.absoluteString == "https://jetledger.io/forgot-password")
    }

    @Test
    func webAppAndSupportAreUnchanged() {
        #expect(AppConstants.Links.webApp.absoluteString == "https://jetledger.io")
        #expect(AppConstants.Links.support.absoluteString == "mailto:support@jetledger.io")
    }

    /// `WebLink` identity keys the `.sheet(item:)` presentation. Two links to the
    /// same page must be the same item, two different pages must not — otherwise
    /// tapping Terms while Privacy is open shows the wrong page or nothing.
    @Test
    func webLinkIdentityFollowsTheURL() {
        #expect(WebLink(AppConstants.Links.terms).id == WebLink(AppConstants.Links.terms).id)
        #expect(WebLink(AppConstants.Links.terms).id != WebLink(AppConstants.Links.privacy).id)
    }
}
