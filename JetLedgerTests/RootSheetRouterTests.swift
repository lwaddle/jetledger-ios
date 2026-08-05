//
//  RootSheetRouterTests.swift
//  JetLedgerTests
//
//  These pin the invariant that fixes a shipped bug: SwiftUI presents one sheet
//  per presentation chain, so a verification sheet asked for by the app root
//  while `LoginView` already had the in-app browser open was silently dropped —
//  no error, no log. The user tapped their verification link, the app came to
//  the front still showing the signup browser, and nothing else happened.
//
//  The structural fix is that there is now exactly ONE sheet slot. Anything
//  that wants a sheet writes to it, and the last write wins. A dropped
//  presentation is no longer expressible.
//

import Testing
import Foundation
@testable import JetLedger

@Suite
struct RootSheetRouterTests {

    private var verifyLink: VerificationLink {
        VerificationLink(url: URL(string: "https://jetledger.io/verify-email/abc123")!)!
    }

    @Test
    @MainActor
    func startsWithNothingPresented() {
        #expect(RootSheetRouter().sheet == nil)
    }

    @Test
    @MainActor
    func showsImmediatelyWhenNothingIsPresented() {
        let router = RootSheetRouter()
        router.show(.verification(verifyLink))
        #expect(router.sheet == .verification(verifyLink))
        #expect(router.pending == nil)
    }

    /// The regression, in the shape the fix actually takes: a `show` while a
    /// sheet is up dismisses first and queues, rather than reassigning the
    /// item mid-presentation. Before the fix these were two competing sheets
    /// and the second was dropped entirely.
    @Test
    @MainActor
    func verificationDismissesAnOpenBrowserThenPresents() {
        let router = RootSheetRouter()
        router.show(.web(WebLink(AppConstants.Links.signup)))

        router.show(.verification(verifyLink))

        // Dismissal in flight — nothing presented, verification queued.
        #expect(router.sheet == nil)
        #expect(router.pending == .verification(verifyLink))

        // The root's onDismiss fires when the dismissal completes.
        router.presentPendingIfNeeded()
        #expect(router.sheet == .verification(verifyLink))
        #expect(router.pending == nil)
    }

    @Test
    @MainActor
    func browserReplacesAnOpenVerification() {
        let router = RootSheetRouter()
        router.show(.verification(verifyLink))

        router.show(.web(WebLink(AppConstants.Links.terms)))
        router.presentPendingIfNeeded()

        #expect(router.sheet == .web(WebLink(AppConstants.Links.terms)))
    }

    /// onDismiss fires on every dismissal, including ordinary user-initiated
    /// ones. With nothing queued it must not resurrect a sheet.
    @Test
    @MainActor
    func ordinaryDismissalDoesNotRepresentAnything() {
        let router = RootSheetRouter()
        router.show(.web(WebLink(AppConstants.Links.terms)))
        router.sheet = nil  // what SwiftUI does when the user swipes down

        router.presentPendingIfNeeded()

        #expect(router.sheet == nil)
    }

    /// A queued sheet must not outlive an explicit dismiss and pop up later.
    @Test
    @MainActor
    func dismissDropsAnythingQueued() {
        let router = RootSheetRouter()
        router.show(.web(WebLink(AppConstants.Links.signup)))
        router.show(.verification(verifyLink))

        router.dismiss()
        router.presentPendingIfNeeded()

        #expect(router.sheet == nil)
        #expect(router.pending == nil)
    }

    @Test
    @MainActor
    func dismissClearsTheSlot() {
        let router = RootSheetRouter()
        router.show(.web(WebLink(AppConstants.Links.privacy)))

        router.dismiss()

        #expect(router.sheet == nil)
    }

    /// Identity drives `.sheet(item:)`. Two different destinations must not
    /// share an id, or swapping one for the other would present nothing.
    @Test
    @MainActor
    func webAndVerificationNeverShareAnIdentity() {
        let web = RootSheet.web(WebLink(AppConstants.Links.signup))
        let verification = RootSheet.verification(verifyLink)
        #expect(web.id != verification.id)
    }

    @Test
    @MainActor
    func identityFollowsTheDestination() {
        #expect(RootSheet.web(WebLink(AppConstants.Links.terms)).id
                == RootSheet.web(WebLink(AppConstants.Links.terms)).id)
        #expect(RootSheet.web(WebLink(AppConstants.Links.terms)).id
                != RootSheet.web(WebLink(AppConstants.Links.privacy)).id)
    }
}
