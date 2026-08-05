//
//  RootSheetRouter.swift
//  JetLedger
//
//  The app's single sheet slot.
//
//  Exists because of a shipped bug: SwiftUI presents one sheet per presentation
//  chain. The verification sheet was attached to the WindowGroup while the
//  in-app browser was attached to LoginView — a descendant — so when a user
//  signed up, went to read their mail, and tapped the verification link, the
//  app came to the front with the signup browser still open and the root's
//  request to present was silently dropped. No error, no log, no recovery
//  except knowing to close the browser first.
//
//  Routing every root-level sheet through one slot makes that unrepresentable:
//  there is only ever one presentation to conflict with, and the last caller
//  wins. Views ask the router instead of owning `@State` of their own.
//
//  Sheets presented from *within* a presented sheet are a legal chain and do
//  not belong here — this is only for sheets whose natural owner is the root.
//

import SwiftUI

/// What the root sheet is currently showing.
enum RootSheet: Identifiable, Equatable {
    /// A public jetledger.io page in the in-app browser.
    case web(WebLink)
    /// A tapped email-verification universal link.
    case verification(VerificationLink)

    /// Drives `.sheet(item:)`. The case is part of the identity so that
    /// swapping a browser for a verification is seen as a different sheet
    /// rather than a no-op.
    var id: String {
        switch self {
        case .web(let link): "web-\(link.id)"
        case .verification(let link): "verification-\(link.id)"
        }
    }
}

@Observable
final class RootSheetRouter {
    /// The one slot. Bound directly by the root's `.sheet(item:)`, so SwiftUI
    /// clears it when the user dismisses.
    var sheet: RootSheet?

    /// Queued while another sheet is being dismissed. See `show(_:)`.
    private(set) var pending: RootSheet?

    /// Presents `destination`, replacing anything already showing.
    ///
    /// When a sheet is already up this does NOT just reassign the item.
    /// Whether SwiftUI re-presents on an item change mid-presentation is not
    /// contractual, and this path is the App Store submission path — so the
    /// replacement is done explicitly: dismiss, then present from the root's
    /// `onDismiss`, which fires only after the dismissal actually completes.
    /// No timers, no guessing at animation durations.
    func show(_ destination: RootSheet) {
        guard sheet != nil else {
            sheet = destination
            return
        }
        pending = destination
        sheet = nil
    }

    /// Called by the root's `.sheet(onDismiss:)`. Presents whatever `show(_:)`
    /// queued behind the sheet that just went away.
    func presentPendingIfNeeded() {
        guard let next = pending else { return }
        pending = nil
        sheet = next
    }

    func dismiss() {
        pending = nil
        sheet = nil
    }
}
