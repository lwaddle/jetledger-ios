//
//  AuthFlowView.swift
//  JetLedger
//

import SwiftUI

enum AuthDestination: Hashable {
    case mfaVerify(mfaToken: String)
}

struct AuthFlowView: View {
    @Environment(AuthService.self) private var authService
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LoginView()
                .navigationDestination(for: AuthDestination.self) { destination in
                    switch destination {
                    case .mfaVerify(let mfaToken):
                        MFAVerifyView(mfaToken: mfaToken)
                            .navigationBarBackButtonHidden(true)
                    }
                }
        }
        .onChange(of: authService.authState) { _, newState in
            switch newState {
            case .mfaRequired(let mfaToken):
                path = NavigationPath()
                path.append(AuthDestination.mfaVerify(mfaToken: mfaToken))
            case .unauthenticated, .authenticated, .offlineReady, .loading:
                path = NavigationPath()
            }
        }
    }
}
