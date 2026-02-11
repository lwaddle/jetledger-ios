//
//  JetLedgerApp.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

@main
struct JetLedgerApp: App {
    @State private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            Group {
                switch authService.authState {
                case .loading:
                    ProgressView("Loading...")
                case .unauthenticated:
                    LoginView()
                case .mfaRequired(let factorId):
                    MFAVerifyView(factorId: factorId)
                case .authenticated:
                    authenticatedPlaceholder
                }
            }
            .environment(authService)
        }
    }

    private var authenticatedPlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Welcome to JetLedger")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Main screen coming soon")
                .foregroundStyle(.secondary)
            Button("Sign Out") {
                Task { await authService.signOut() }
            }
            .buttonStyle(.bordered)
        }
    }
}
