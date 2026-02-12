//
//  JetLedgerApp.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftData
import SwiftUI

@main
struct JetLedgerApp: App {
    @State private var authService = AuthService()
    @State private var accountService: AccountService?

    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([
                LocalReceipt.self,
                LocalReceiptPage.self,
                CachedAccount.self,
                CachedTripReference.self,
            ])
            modelContainer = try ModelContainer(for: schema)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

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
                    if let accountService {
                        MainView()
                            .environment(accountService)
                    } else {
                        ProgressView("Loading accounts...")
                    }
                }
            }
            .environment(authService)
            .modelContainer(modelContainer)
            .onChange(of: authService.authState) { _, newState in
                handleAuthStateChange(newState)
            }
        }
    }

    private func handleAuthStateChange(_ state: AuthState) {
        switch state {
        case .authenticated:
            let context = modelContainer.mainContext
            let service = AccountService(
                supabase: authService.supabase,
                modelContext: context
            )
            accountService = service
            Task {
                await service.loadAccounts()
                await service.loadProfile()
            }
        case .unauthenticated:
            accountService?.clearAllData()
            accountService = nil
        default:
            break
        }
    }
}
