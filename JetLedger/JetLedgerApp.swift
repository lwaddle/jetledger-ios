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
import UserNotifications

@main
struct JetLedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var authService = AuthService()
    @State private var accountService: AccountService?
    @State private var networkMonitor = NetworkMonitor()
    @State private var syncService: SyncService?
    @State private var tripReferenceService: TripReferenceService?
    @State private var pushService: PushNotificationService?

    private let modelContainer: ModelContainer

    init() {
        // Ensure the App Group's Application Support directory exists before
        // SwiftData tries to create its store there (avoids noisy CoreData errors on first launch)
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.SharedContainer.appGroupIdentifier
        ) {
            let supportDir = containerURL.appending(path: "Library/Application Support")
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }

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
                    if let accountService, let syncService, let tripReferenceService, let pushService {
                        MainView()
                            .environment(accountService)
                            .environment(syncService)
                            .environment(tripReferenceService)
                            .environment(pushService)
                    } else {
                        ProgressView("Loading accounts...")
                    }
                }
            }
            .environment(authService)
            .environment(networkMonitor)
            .modelContainer(modelContainer)
            .task {
                UNUserNotificationCenter.current().delegate = appDelegate
            }
            .onChange(of: authService.authState) { _, newState in
                handleAuthStateChange(newState)
            }
            .onOpenURL { url in
                guard url.scheme == "jetledger", url.host == "reset-password" else { return }
                Task {
                    do {
                        try await authService.handlePasswordResetDeepLink(url: url)
                    } catch {
                        authService.errorMessage = "Password reset link is invalid or expired."
                    }
                }
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
                modelContext: context,
                networkMonitor: networkMonitor
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
                modelContext: context,
                supabase: authService.supabase,
                tripReferenceService: tripRefService
            )
            sync.resetStuckUploads()
            sync.migrateTerminalTimestamps()
            syncService = sync

            let push = PushNotificationService(receiptAPI: receiptAPI)
            appDelegate.pushService = push
            if let pendingId = appDelegate.pendingNotificationReceiptId {
                push.pendingDeepLinkReceiptId = pendingId
                appDelegate.pendingNotificationReceiptId = nil
            }
            pushService = push

            Task {
                async let accounts: Void = acctService.loadAccounts()
                async let profile: Void = acctService.loadProfile()
                async let pushReg: Void = push.requestPermissionAndRegister()
                _ = await (accounts, profile, pushReg)
            }

        case .unauthenticated:
            if let pushService {
                let service = pushService
                Task { await service.unregisterToken() }
            }
            appDelegate.pushService = nil
            pushService = nil
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
