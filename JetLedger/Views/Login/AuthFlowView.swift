//
//  AuthFlowView.swift
//  JetLedger
//
//  Created by Loren Waddle on 3/2/26.
//

import SwiftUI

enum AuthDestination: Hashable {
    case mfaVerify(factorId: String)
    case mfaEnrollmentRequired
}

struct AuthFlowView: View {
    @Environment(AuthService.self) private var authService
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LoginView()
                .navigationDestination(for: AuthDestination.self) { destination in
                    switch destination {
                    case .mfaVerify(let factorId):
                        MFAVerifyView(factorId: factorId)
                            .navigationBarBackButtonHidden(true)
                    case .mfaEnrollmentRequired:
                        MFAEnrollmentRequiredView()
                            .navigationBarBackButtonHidden(true)
                    }
                }
        }
        .onChange(of: authService.authState) { _, newState in
            switch newState {
            case .mfaRequired(let factorId):
                path = NavigationPath()
                path.append(AuthDestination.mfaVerify(factorId: factorId))
            case .mfaEnrollmentRequired:
                path = NavigationPath()
                path.append(AuthDestination.mfaEnrollmentRequired)
            case .unauthenticated, .authenticated, .offlineReady, .loading:
                path = NavigationPath()
            }
        }
    }
}
