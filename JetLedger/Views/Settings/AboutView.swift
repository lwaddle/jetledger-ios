//
//  AboutView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct AboutView: View {
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
