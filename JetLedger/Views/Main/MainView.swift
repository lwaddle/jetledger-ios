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
    @Environment(AccountService.self) private var accountService
    @Environment(SyncService.self) private var syncService
    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(PushNotificationService.self) private var pushService
    @Environment(\.horizontalSizeClass) private var sizeClass
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
    @State private var cameraSessionManager = CameraSessionManager()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var canUpload: Bool {
        accountService.selectedAccount?.accountRole?.canUpload ?? true
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if sizeClass == .regular {
                        ToolbarItem(placement: .topBarLeading) {
                            AccountSelectorView()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        } detail: {
            if let selectedReceipt {
                ReceiptDetailView(receipt: selectedReceipt)
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
            SettingsView()
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
                syncService.processQueue()
                cameraSessionManager.scheduleStop()
            }
        }
        .onChange(of: showImport) { _, isShowing in
            if !isShowing {
                syncService.processQueue()
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            syncService.handleNetworkChange(isConnected: isConnected)
        }
        .task(id: accountService.selectedAccount?.id) {
            if let accountId = accountService.selectedAccount?.id {
                await tripReferenceService.loadTripReferences(for: accountId)
                await syncService.fetchRemoteReceipts(for: accountId)
                await syncService.downloadPendingImages()
                await syncService.syncReceiptStatuses()
                syncService.performCleanup()
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
            if phase == .active, let accountId = accountService.selectedAccount?.id {
                let result = SharedImportService.processPendingImports(
                    accountId: accountId,
                    modelContext: modelContext
                )
                if result.imported > 0 {
                    syncService.processQueue()
                }
                if result.failed > 0 {
                    importErrorMessage = "\(result.failed) shared file(s) could not be imported."
                    showImportError = true
                }
                Task {
                    await syncService.fetchRemoteReceipts(for: accountId)
                    await syncService.downloadPendingImages()
                    await syncService.syncReceiptStatuses()
                    syncService.performCleanup()
                }
            }
        }
        .onChange(of: pushService.pendingDeepLinkReceiptId) { _, receiptId in
            guard let receiptId else { return }
            pushService.pendingDeepLinkReceiptId = nil
            navigateToReceipt(serverReceiptId: receiptId)
        }
        .task {
            cameraSessionManager.configure()
            // Process any pending shared imports
            if let accountId = accountService.selectedAccount?.id {
                let result = SharedImportService.processPendingImports(
                    accountId: accountId,
                    modelContext: modelContext
                )
                if result.failed > 0 {
                    importErrorMessage = "\(result.failed) shared file(s) could not be imported."
                    showImportError = true
                }
            }
            syncService.processQueue()
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
                // Brand bar: logo left, account selector right (compact only)
                HStack {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 28)
                    Spacer()
                    if sizeClass == .compact {
                        AccountSelectorView()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)

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

    // MARK: - Deep Link Navigation

    private func navigateToReceipt(serverReceiptId: UUID) {
        let descriptor = FetchDescriptor<LocalReceipt>()
        guard let receipts = try? modelContext.fetch(descriptor) else { return }

        if let match = receipts.first(where: { $0.serverReceiptId == serverReceiptId }) {
            selectedReceipt = match
        } else if let accountId = accountService.selectedAccount?.id {
            Task {
                await syncService.fetchRemoteReceipts(for: accountId)
                let refreshed = (try? modelContext.fetch(descriptor)) ?? []
                if let match = refreshed.first(where: { $0.serverReceiptId == serverReceiptId }) {
                    selectedReceipt = match
                }
            }
        }
    }

}
