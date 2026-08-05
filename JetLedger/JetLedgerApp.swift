//
//  JetLedgerApp.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftData
import SwiftUI
import UserNotifications

@main
struct JetLedgerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var authService = AuthService()
    @State private var accountService: AccountService?
    @State private var networkMonitor = NetworkMonitor()
    @State private var syncService: SyncService?
    @State private var tripReferenceService: TripReferenceService?
    @State private var pushService: PushNotificationService?
    @State private var receiptListService: ReceiptListService?
    @State private var receiptImageDownloader: ReceiptImageDownloader?
    @State private var biometricService = BiometricAuthService()
    @State private var passkeyService = PasskeyAuthService()
    // Process-level — survives auth-state transitions so we don't tear down
    // and rebuild the AVCaptureSession on every sign-in/sign-out cycle.
    @State private var cameraSessionManager = CameraSessionManager()
    @State private var showUserMismatchAlert = false
    @State private var mismatchOldEmail: String?
    @State private var showBiometricPrompt = false
    // The app's single sheet slot. Every root-level sheet goes through it so
    // two of them can never compete — see RootSheetRouter for the bug that
    // made this necessary.
    @State private var sheetRouter = RootSheetRouter()

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
            rootView
            .environment(authService)
            .environment(networkMonitor)
            .environment(sheetRouter)
            .environment(biometricService)
            .environment(cameraSessionManager)
            .modelContainer(modelContainer)
            .task {
                // Notification-center delegate is set in AppDelegate's
                // didFinishLaunching — early enough to catch launch notifications.
                authService.biometricService = biometricService
                authService.passkeyService = passkeyService
                await authService.restoreSession()
                await authService.refreshSessionIfNeeded()
            }
            .onChange(of: authService.authState) { _, newState in
                handleAuthStateChange(newState)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await authService.refreshSessionIfNeeded() }
                }
            }
            .alert(
                "Sign In with \(biometricService.biometricLabel)",
                isPresented: $showBiometricPrompt
            ) {
                Button("Enable") {
                    Task {
                        do {
                            try await biometricService.enableBiometricLogin(
                                apiClient: authService.apiClient
                            )
                        } catch {
                            // Non-fatal — user can enable later in Settings
                        }
                        biometricService.hasPromptedUser = true
                    }
                }
                Button("Not Now", role: .cancel) {
                    biometricService.hasPromptedUser = true
                }
            } message: {
                Text("Use \(biometricService.biometricLabel) to sign in without entering your password next time.")
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
            .onOpenURL { url in
                // Universal links arrive here (AppDelegate deliberately does
                // not implement continueUserActivity, which would intercept
                // them). Anything that is not a verification link is ignored:
                // the app claims only /verify-email/* in its AASA, and the
                // pages it opens itself go through the router below.
                if let link = VerificationLink(url: url) {
                    // Replaces whatever is showing. The signup browser is
                    // usually still open at this point — the user left it to
                    // go read their mail — and before the router existed that
                    // made this presentation silently fail.
                    sheetRouter.show(.verification(link))
                }
            }
            .sheet(item: $sheetRouter.sheet, onDismiss: {
                // Fires only after a dismissal completes, which is how a
                // replacement sheet gets presented without racing the
                // animation. Usually a no-op.
                sheetRouter.presentPendingIfNeeded()
            }) { destination in
                // The only root-level sheet. A sheet rather than a root-view
                // swap: it presents identically from every authState and
                // cannot strand a user mid-capture. It also sits above the
                // TermsGateView layer without bypassing it — verification is
                // not a gated action.
                switch destination {
                case .web(let link):
                    SafariView(url: link.url)
                case .verification(let link):
                    EmailVerificationView(link: link)
                        .environment(authService)
                }
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch authService.authState {
        case .loading:
            ProgressView("Loading...")
        case .unauthenticated, .mfaRequired:
            AuthFlowView()
        case .authenticated:
            if let accountService, let syncService, let tripReferenceService, let pushService,
               let receiptListService, let receiptImageDownloader {
                // The terms gate is an opaque layer over MainView, not a
                // replacement: replacing would tear down services and any
                // in-progress capture over a condition one tap resolves.
                // Presentation layers (an already-open capture sheet) stay
                // above it and can finish — their uploads park on the server's
                // 403 backstop and resume after acceptance. Never rendered in
                // .offlineReady: the gate exists only on live server signal.
                ZStack {
                    MainView()
                        .environment(accountService)
                        .environment(syncService)
                        .environment(tripReferenceService)
                        .environment(pushService)
                        .environment(receiptListService)
                        .environment(receiptImageDownloader)
                        .accessibilityHidden(authService.termsAcceptanceRequired)

                    if authService.termsAcceptanceRequired {
                        TermsGateView()
                            .environment(accountService)
                    }
                }
            } else {
                ProgressView("Loading accounts...")
            }
        case .offlineReady:
            if let accountService, let syncService, let tripReferenceService, let pushService,
               let receiptListService, let receiptImageDownloader {
                MainView(isOfflineMode: true)
                    .environment(accountService)
                    .environment(syncService)
                    .environment(tripReferenceService)
                    .environment(pushService)
                    .environment(receiptListService)
                    .environment(receiptImageDownloader)
            } else {
                ProgressView("Loading...")
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
                apiClient: authService.apiClient,
                modelContext: context
            )
            if let loginAccounts = authService.loginAccounts {
                acctService.seedAccounts(loginAccounts, profile: authService.loginProfile)
            }
            // Accounts refreshes (foreground, pull-to-refresh) are how the
            // terms signal reaches the app mid-install; route it to the gate.
            let auth = authService
            acctService.onTermsStatus = { auth.applyTermsStatus($0) }
            accountService = acctService

            let tripRefService = TripReferenceService(
                apiClient: authService.apiClient,
                modelContext: context,
                networkMonitor: networkMonitor
            )
            tripReferenceService = tripRefService

            let receiptAPI = ReceiptAPIService(apiClient: authService.apiClient)
            let r2Upload = R2UploadService()

            let sync = SyncService(
                receiptAPI: receiptAPI,
                r2Upload: r2Upload,
                networkMonitor: networkMonitor,
                modelContext: context
            )
            sync.resetStuckUploads()
            sync.migrateTerminalTimestamps()
            syncService?.shutdown()
            syncService = sync

            receiptListService = ReceiptListService(
                receiptAPI: receiptAPI,
                networkMonitor: networkMonitor,
                modelContext: context
            )
            receiptImageDownloader = ReceiptImageDownloader(
                receiptAPI: receiptAPI,
                modelContext: context
            )

            let push = PushNotificationService(receiptAPI: receiptAPI)
            appDelegate.pushService = push
            if let pendingId = appDelegate.pendingNotificationReceiptId {
                push.pendingDeepLinkReceiptId = pendingId
                appDelegate.pendingNotificationReceiptId = nil
            }
            pushService = push
            authService.pushService = push

            authService.onWillSignOut = {
                await push.unregisterToken()
            }

            Task {
                async let accounts: Void = acctService.loadAccounts()
                async let user: Void = acctService.loadCurrentUser()
                async let pushReg: Void = push.requestPermissionAndRegister()
                _ = await (accounts, user, pushReg)

                // Save offline identity from the now-loaded account data
                if let account = acctService.selectedAccount,
                   let userId = authService.currentUserId {
                    let identity = OfflineIdentity(
                        userId: userId,
                        email: acctService.userProfile?.email ?? authService.currentUserEmail ?? "",
                        accountId: account.id,
                        accountName: account.name,
                        role: account.role
                    )
                    OfflineIdentity.save(identity)
                }

                // Prompt to enable biometric login (once per device)
                if biometricService.isBiometricsAvailable
                    && !biometricService.hasPromptedUser
                    && !biometricService.isBiometricLoginEnabled {
                    showBiometricPrompt = true
                }
            }

        case .offlineReady:
            guard let identity = OfflineIdentity.load() else {
                authService.authState = .unauthenticated
                return
            }

            let context = modelContainer.mainContext

            let acctService = AccountService(
                apiClient: authService.apiClient,
                modelContext: context
            )
            acctService.loadAccountsFromCache()
            acctService.loadOfflineProfile(from: identity)
            accountService = acctService

            let tripRefService = TripReferenceService(
                apiClient: authService.apiClient,
                modelContext: context,
                networkMonitor: networkMonitor
            )
            tripReferenceService = tripRefService

            let receiptAPI = ReceiptAPIService(apiClient: authService.apiClient)

            let sync = SyncService(
                receiptAPI: receiptAPI,
                r2Upload: R2UploadService(),
                networkMonitor: networkMonitor,
                modelContext: context
            )
            syncService?.shutdown()
            syncService = sync

            receiptListService = ReceiptListService(
                receiptAPI: receiptAPI,
                networkMonitor: networkMonitor,
                modelContext: context
            )
            receiptImageDownloader = ReceiptImageDownloader(
                receiptAPI: receiptAPI,
                modelContext: context
            )

            let push = PushNotificationService(receiptAPI: receiptAPI)
            pushService = push
            authService.pushService = push

        case .unauthenticated:
            let hasOfflineIdentity = OfflineIdentity.load() != nil

            if let pushService {
                let service = pushService
                Task { await service.unregisterToken() }
            }
            appDelegate.pushService = nil
            pushService = nil
            authService.pushService = nil
            // Stop in-flight uploads BEFORE the service is discarded and before
            // clearAllData() below deletes the models they're mutating.
            syncService?.shutdown()
            syncService = nil
            receiptListService = nil
            receiptImageDownloader = nil
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
