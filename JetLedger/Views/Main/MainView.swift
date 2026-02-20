//
//  MainView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AccountService.self) private var accountService
    @Environment(SyncService.self) private var syncService
    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var showCapture = false
    @State private var showImport = false
    @State private var showFilePicker = false
    @State private var importedURLs: [URL] = []
    @State private var selectedReceipt: LocalReceipt?
    @State private var showSyncError = false
    @State private var showImportError = false
    @State private var importErrorMessage: String?
    @State private var cameraSessionManager = CameraSessionManager()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            if sizeClass == .regular {
                                importButton
                                scanButton
                            }
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                }
        } detail: {
            if let selectedReceipt {
                ReceiptDetailView(receipt: selectedReceipt)
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
        .onChange(of: accountService.selectedAccount?.id) { _, accountId in
            if let accountId {
                Task {
                    await tripReferenceService.loadTripReferences(for: accountId)
                }
            }
        }
        .onChange(of: syncService.lastError) { _, error in
            if error != nil {
                showSyncError = true
            }
        }
        .alert("Upload Error", isPresented: $showSyncError) {
            Button("Retry") {
                syncService.lastError = nil
                syncService.retryAllFailed()
            }
            Button("OK", role: .cancel) { syncService.lastError = nil }
        } message: {
            Text(syncService.lastError ?? "")
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
            }
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
            await syncService.syncReceiptStatuses()
            syncService.performCleanup()
            if let accountId = accountService.selectedAccount?.id {
                await tripReferenceService.loadTripReferences(for: accountId)
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
                // Brand bar: logo left, account selector right
                HStack {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 28)
                    Spacer()
                    AccountSelectorView()
                }
                .padding(.horizontal)
                .padding(.top, 12)

                // Scan + Import buttons (inline on iPhone only)
                if sizeClass == .compact {
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
                        .disabled(account.accountRole?.canUpload != true)
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
                        .disabled(account.accountRole?.canUpload != true)
                        .padding(.horizontal)

                        if account.accountRole?.canUpload != true {
                            Text("Viewers cannot upload receipts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var scanButton: some View {
        Button {
            showCapture = true
        } label: {
            Label("Scan Receipt", systemImage: "camera.fill")
        }
        .disabled(accountService.selectedAccount?.accountRole?.canUpload != true)
    }

    private var importButton: some View {
        Button {
            showFilePicker = true
        } label: {
            Label("Import from Files", systemImage: "doc.badge.plus")
        }
        .disabled(accountService.selectedAccount?.accountRole?.canUpload != true)
    }
}
