//
//  SafariView.swift
//  JetLedger
//
//  In-app browser for the public jetledger.io pages (privacy, terms, signup,
//  password reset). SFSafariViewController rather than a plain SwiftUI `Link`
//  so the pages open *over* the app instead of switching to Safari — App Store
//  Review Guideline 5.1.1(i) asks for the privacy policy to be reachable
//  "within the app", and a hand-off to another app answers that weakly.
//

import SafariServices
import SwiftUI

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Color.accentColor)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        // SFSafariViewController's URL is fixed at init. Presenting a different
        // page means presenting a new sheet, which is what `.sheet(item:)` on a
        // changing WebLink does.
    }
}

/// A URL to present in a `SafariView` sheet. `.sheet(item:)` needs an
/// `Identifiable` payload, and conforming `URL` itself would be a global
/// extension on a Foundation type for the sake of one call site.
struct WebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }

    init(_ url: URL) {
        self.url = url
    }
}

extension View {
    /// Presents `link` in an in-app Safari sheet, clearing it on dismiss.
    func safariSheet(_ link: Binding<WebLink?>) -> some View {
        sheet(item: link) { SafariView(url: $0.url) }
    }
}
