//
//  JetLedgerApp.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Auth
import Supabase
import SwiftData
import SwiftUI

@main
struct JetLedgerApp: App {
    @State private var authService = AuthService()
    @State private var accountService: AccountService?
    @State private var networkMonitor = NetworkMonitor()
    @State private var syncService: SyncService?
    @State private var tripReferenceService: TripReferenceService?

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
                    if let accountService, let syncService, let tripReferenceService {
                        MainView()
                            .environment(accountService)
                            .environment(syncService)
                            .environment(tripReferenceService)
                    } else {
                        ProgressView("Loading accounts...")
                    }
                }
            }
            .environment(authService)
            .environment(networkMonitor)
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

            let acctService = AccountService(
                supabase: authService.supabase,
                modelContext: context
            )
            accountService = acctService

            let tripRefService = TripReferenceService(
                supabase: authService.supabase,
                modelContext: context
            )
            tripReferenceService = tripRefService

            let receiptAPI = ReceiptAPIService(
                baseURL: AppConstants.WebAPI.baseURL,
                sessionProvider: { [weak authService] in
                    try? await authService?.supabase.auth.session.accessToken
                }
            )
            let r2Upload = R2UploadService()

            let sync = SyncService(
                receiptAPI: receiptAPI,
                r2Upload: r2Upload,
                networkMonitor: networkMonitor,
                modelContext: context
            )
            sync.resetStuckUploads()
            syncService = sync

            Task {
                await acctService.loadAccounts()
                await acctService.loadProfile()
            }

        case .unauthenticated:
            syncService = nil
            tripReferenceService?.clearCache()
            tripReferenceService = nil
            accountService?.clearAllData()
            accountService = nil

        default:
            break
        }
    }
}
