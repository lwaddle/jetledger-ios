//
//  MainView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    var isOfflineMode: Bool = false

    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(SyncService.self) private var syncService
    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(PushNotificationService.self) private var pushService
    @Environment(CameraSessionManager.self) private var cameraSessionManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var showCapture = false
    @State private var showImport = false
    @State private var showFilePicker = false
    @State private var importedURLs: [URL] = []
    @State private var selectedReceipt: LocalReceipt?
    @State private var syncErrorMessage: String?
    @State private var showImportError = false
    @State private var importErrorMessage: String?
    @State private var showSettings = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var canUpload: Bool {
        // No account yet (still loading) → don't flash the viewer banner.
        // Account present but role unrecognized → fail closed; an unknown
        // future role must not silently get upload UI.
        guard let account = accountService.selectedAccount else { return true }
        return account.accountRole?.canUpload ?? false
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        AccountSelectorView()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        } detail: {
            if let selectedReceipt {
                // .id resets the detail view's @State (gallery page, delete
                // confirmation, sheets) when the iPad selection changes —
                // without it, a confirmation opened for receipt A can execute
                // against receipt B.
                ReceiptDetailView(receipt: selectedReceipt, selectedReceipt: $selectedReceipt)
                    .id(selectedReceipt.id)
            } else if !canUpload {
                ContentUnavailableView(
                    "Read-Only Access",
                    systemImage: "eye.fill",
                    description: Text("Viewers can browse receipts but cannot upload. Contact your administrator to request editor access.")
                )
            } else {
                ContentUnavailableView(
                    "Select a Receipt",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a receipt from the list to view its details.")
                )
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            if let account = accountService.selectedAccount {
                CaptureFlowView(accountId: account.id, cameraSessionManager: cameraSessionManager)
            }
        }
        .sheet(isPresented: $showImport) {
            importedURLs = []
        } content: {
            if let account = accountService.selectedAccount {
                ImportFlowView(accountId: account.id, urls: importedURLs)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(isOfflineMode: isOfflineMode)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty:
                importedURLs = urls
                showImport = true
            default:
                break
            }
        }
        .onChange(of: showCapture) { _, isShowing in
            if !isShowing {
                if !isOfflineMode {
                    syncService.processQueue()
                }
                // Defer the session stop — re-opens within 30s skip the
                // warming overhead and avoid the FigXPC pause noise
                // (one pair per output) emitted by an immediate stop.
                cameraSessionManager.scheduleStop(after: 30)
            } else {
                cameraSessionManager.cancelScheduledStop()
            }
        }
        .onChange(of: showImport) { _, isShowing in
            if !isShowing, !isOfflineMode {
                syncService.processQueue()
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            if !isOfflineMode {
                syncService.handleNetworkChange(isConnected: isConnected)
            }
        }
        .onChange(of: accountService.selectedAccount?.id) { _, _ in
            // The detail column must not keep showing the previous account's
            // receipt after a switch.
            selectedReceipt = nil
        }
        .task(id: accountService.selectedAccount?.id) {
            if !isOfflineMode, let accountId = accountService.selectedAccount?.id {
                await tripReferenceService.loadTripReferences(for: accountId)
                await syncService.syncReceiptStatuses()
                runCleanup()
            }
        }
        .onChange(of: syncService.lastError) { _, error in
            if let error {
                syncErrorMessage = error
            }
        }
        .alert("Upload Error", isPresented: Binding(
            get: { syncErrorMessage != nil },
            set: { if !$0 { syncErrorMessage = nil } }
        )) {
            Button("Retry") {
                syncService.lastError = nil
                syncErrorMessage = nil
                syncService.retryAllFailed()
            }
            Button("OK", role: .cancel) {
                syncService.lastError = nil
                syncErrorMessage = nil
            }
        } message: {
            Text(syncErrorMessage ?? "")
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK") { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isOfflineMode, let accountId = accountService.selectedAccount?.id {
                let result = SharedImportService.processPendingImports(
                    accountId: accountId,
                    modelContext: modelContext
                )
                if result.imported > 0 {
                    syncService.processQueue()
                }
                if let problem = result.problemMessage {
                    importErrorMessage = problem
                    showImportError = true
                }
                Task {
                    await syncService.syncReceiptStatuses()
                    runCleanup()
                }
            }
        }
        // initial: true — on a cold launch from a notification tap, the deep-link
        // id is set before MainView exists; without an initial evaluation the
        // onChange never fires and the tap lands on a plain list.
        .onChange(of: pushService.pendingDeepLinkReceiptId, initial: true) { _, receiptId in
            guard let receiptId else { return }
            pushService.pendingDeepLinkReceiptId = nil
            navigateToReceipt(serverReceiptId: receiptId)
        }
        .task {
            cameraSessionManager.configure()
            // Process any pending shared imports
            if !isOfflineMode, let accountId = accountService.selectedAccount?.id {
                let result = SharedImportService.processPendingImports(
                    accountId: accountId,
                    modelContext: modelContext
                )
                if let problem = result.problemMessage {
                    importErrorMessage = problem
                    showImportError = true
                }
            }
            if !isOfflineMode {
                syncService.processQueue()
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if accountService.isLoading {
            VStack {
                Spacer()
                ProgressView("Loading accounts...")
                Spacer()
            }
        } else if let account = accountService.selectedAccount {
            accountContent(account)
        } else if let loadError = accountService.loadError {
            ContentUnavailableView {
                Label("Unable to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") {
                    Task { await accountService.loadAccounts() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "building.2",
                description: Text("You don't belong to any accounts. Contact your administrator.")
            )
        }
    }

    @ViewBuilder
    private func accountContent(_ account: CachedAccount) -> some View {
        ReceiptListView(accountId: account.id, selectedReceipt: $selectedReceipt) {
            VStack(spacing: 24) {
                // Offline banner
                if isOfflineMode {
                    offlineBanner
                }

                // Brand bar — logo only; the account selector lives in the
                // toolbar so long org names get the full nav-bar width.
                HStack {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 28)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, isOfflineMode ? 0 : 12)

                // Scan + Import buttons
                if canUpload {
                    VStack(spacing: 12) {
                        Button {
                            showCapture = true
                        } label: {
                            Label("Scan Receipt", systemImage: "camera.fill")
                                .foregroundStyle(.white)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)
                        .padding(.horizontal)

                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Import from Files", systemImage: "doc.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.accentColor)
                        .padding(.horizontal)
                    }
                } else {
                    viewerBanner
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var offlineBanner: some View {
        Button {
            authService.authState = .unauthenticated
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.subheadline)
                if networkMonitor.isConnected {
                    let queuedCount = queuedReceiptCount
                    Text(queuedCount > 0
                         ? "Sign in to upload \(queuedCount) receipt\(queuedCount == 1 ? "" : "s")"
                         : "Sign in to sync receipts")
                        .font(.subheadline)
                } else {
                    Text("Offline — sign in to sync receipts")
                        .font(.subheadline)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.vertical, 10)
            // Fixed .orange under white text is ~2.1:1 contrast; the darker
            // brown-orange passes WCAG for the banner text in both modes.
            .background(Color(red: 0.72, green: 0.36, blue: 0.0))
        }
    }

    private var queuedReceiptCount: Int {
        guard let accountId = accountService.selectedAccount?.id else { return 0 }
        let allReceipts = (try? modelContext.fetch(FetchDescriptor<LocalReceipt>())) ?? []
        return allReceipts.filter {
            $0.accountId == accountId && ($0.syncStatus == .queued || $0.syncStatus == .failed)
        }.count
    }

    private var viewerBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Read-Only Access")
                .font(.headline)
            Text("Viewers can browse receipts but cannot scan or upload. Contact your administrator to request editor access.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Cleanup

    /// Runs retention cleanup and drops the detail selection if its record was
    /// deleted — a live `ReceiptDetailView` touching a destroyed `@Model`
    /// crashes on the next body evaluation. The selected id is captured before
    /// the delete so the check never reads a destroyed model.
    private func runCleanup() {
        let selectedId = selectedReceipt?.id
        let deletedIds = syncService.performCleanup()
        if let selectedId, deletedIds.contains(selectedId) {
            selectedReceipt = nil
        }
    }

    // MARK: - Deep Link Navigation

    private func navigateToReceipt(serverReceiptId: UUID) {
        let descriptor = FetchDescriptor<LocalReceipt>()
        guard let receipts = try? modelContext.fetch(descriptor) else { return }

        if let match = receipts.first(where: { $0.serverReceiptId == serverReceiptId }) {
            selectedReceipt = match
        }
    }

}
