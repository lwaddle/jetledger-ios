//
//  AboutView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct AboutView: View {
    /// Presented locally, NOT through `RootSheetRouter`. This view lives
    /// inside MainView's Settings sheet, and the router's slot is at the
    /// scene root — a root sheet cannot present while a descendant's sheet is
    /// up, so routing these silently did nothing. A sheet presented from
    /// within a presented sheet is a legal chain and works.
    ///
    /// The router is for presentations that must preempt whatever is showing
    /// (a tapped universal link). A button in an already-presented view has
    /// nothing to preempt.
    @State private var webLink: WebLink?

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 28)
                    Text(Bundle.main.versionString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: AppConstants.Links.webApp) {
                    Label("JetLedger Web App", systemImage: "globe")
                }
                Link(destination: AppConstants.Links.support) {
                    Label("Contact Support", systemImage: "envelope")
                }
            }

            // These open in an in-app Safari sheet rather than handing off to
            // Safari like the two links above — see SafariView for why.
            Section("Legal") {
                Button {
                    webLink = WebLink(AppConstants.Links.privacy)
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Button {
                    webLink = WebLink(AppConstants.Links.terms)
                } label: {
                    Label("Terms of Service", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .safariSheet($webLink)
    }

}
