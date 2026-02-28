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
    @State private var showUserMismatchAlert = false
    @State private var mismatchOldEmail: String?

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
                case .mfaEnrollmentRequired:
                    MFAEnrollmentRequiredView()
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
                case .offlineReady:
                    if let accountService, let syncService, let tripReferenceService, let pushService {
                        MainView(isOfflineMode: true)
                            .environment(accountService)
                            .environment(syncService)
                            .environment(tripReferenceService)
                            .environment(pushService)
                    } else {
                        ProgressView("Loading...")
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
            .alert("Different Account", isPresented: $showUserMismatchAlert) {
                Button("Delete Offline Receipts", role: .destructive) {
                    clearAllLocalData()
                    // Re-trigger authenticated flow now that data is cleared
                    handleAuthStateChange(.authenticated)
                }
                Button("Sign Out", role: .cancel) {
                    Task { await authService.signOut() }
                }
            } message: {
                Text("You previously captured receipts offline as \(mismatchOldEmail ?? "another user"). Signing in as a different account will delete those offline receipts.")
            }
        }
    }

    private func handleAuthStateChange(_ state: AuthState) {
        switch state {
        case .authenticated:
            // Check for user mismatch with existing offline identity
            if let existingIdentity = OfflineIdentity.load(),
               let currentUserId = authService.currentUserId,
               existingIdentity.userId != currentUserId {
                // Check if there are orphaned queued/failed receipts
                let context = modelContainer.mainContext
                let allReceipts = (try? context.fetch(FetchDescriptor<LocalReceipt>())) ?? []
                let orphanedReceipts = allReceipts.filter {
                    $0.syncStatus == .queued || $0.syncStatus == .failed
                }
                if !orphanedReceipts.isEmpty {
                    mismatchOldEmail = existingIdentity.email
                    showUserMismatchAlert = true
                    return
                } else {
                    clearAllLocalData()
                }
            }

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

                // Save offline identity from the now-loaded account data
                if let account = acctService.selectedAccount,
                   let userId = authService.currentUserId {
                    let identity = OfflineIdentity(
                        userId: userId,
                        email: acctService.userProfile?.email ?? "",
                        accountId: account.id,
                        accountName: account.name,
                        role: account.role
                    )
                    OfflineIdentity.save(identity)
                }
            }

        case .offlineReady:
            guard let identity = OfflineIdentity.load() else {
                authService.authState = .unauthenticated
                return
            }

            let context = modelContainer.mainContext

            let acctService = AccountService(
                supabase: authService.supabase,
                modelContext: context
            )
            acctService.loadAccountsFromCache()
            acctService.loadOfflineProfile(from: identity)
            accountService = acctService

            let tripRefService = TripReferenceService(
                supabase: authService.supabase,
                modelContext: context,
                networkMonitor: networkMonitor
            )
            tripReferenceService = tripRefService

            let receiptAPI = ReceiptAPIService(
                baseURL: AppConstants.WebAPI.baseURL,
                sessionProvider: { nil }
            )

            let sync = SyncService(
                receiptAPI: receiptAPI,
                r2Upload: R2UploadService(),
                networkMonitor: networkMonitor,
                modelContext: context,
                supabase: authService.supabase,
                tripReferenceService: tripRefService
            )
            syncService = sync

            let push = PushNotificationService(receiptAPI: receiptAPI)
            pushService = push

        case .unauthenticated:
            let hasOfflineIdentity = OfflineIdentity.load() != nil

            if let pushService {
                let service = pushService
                Task { await service.unregisterToken() }
            }
            appDelegate.pushService = nil
            pushService = nil
            syncService = nil
            tripReferenceService?.clearCache()
            tripReferenceService = nil

            if hasOfflineIdentity {
                // Keep local data — user may continue offline
                accountService = nil
            } else {
                accountService?.clearAllData()
                accountService = nil
                OfflineIdentity.clear()
            }

            // Auto-enter offline mode when no network and identity exists
            if hasOfflineIdentity && !networkMonitor.isConnected {
                authService.enterOfflineMode()
            }

        default:
            break
        }
    }

    private func clearAllLocalData() {
        let context = modelContainer.mainContext
        let allReceipts = (try? context.fetch(FetchDescriptor<LocalReceipt>())) ?? []
        for receipt in allReceipts {
            ImageUtils.deleteReceiptImages(receiptId: receipt.id)
            context.delete(receipt)
        }
        let allAccounts = (try? context.fetch(FetchDescriptor<CachedAccount>())) ?? []
        for account in allAccounts { context.delete(account) }
        let allTrips = (try? context.fetch(FetchDescriptor<CachedTripReference>())) ?? []
        for trip in allTrips { context.delete(trip) }
        try? context.save()
        OfflineIdentity.clear()
        UserDefaults.standard.removeObject(forKey: "selectedAccountId")
    }
}
