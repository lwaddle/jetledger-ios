//
//  AboutView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct AboutView: View {
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
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

}
