//
//  MainView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct MainView: View {
    @Environment(AccountService.self) private var accountService
    @Environment(SyncService.self) private var syncService
    @Environment(TripReferenceService.self) private var tripReferenceService
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showCapture = false
    @State private var selectedReceipt: LocalReceipt?
    @State private var showSyncError = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("JetLedger")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            if sizeClass == .regular {
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
                CaptureFlowView(accountId: account.id)
            }
        }
        .onChange(of: showCapture) { _, isShowing in
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
            Button("OK") { syncService.lastError = nil }
        } message: {
            Text(syncService.lastError ?? "")
        }
        .task {
            syncService.processQueue()
            await syncService.syncReceiptStatuses()
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
        VStack(spacing: 0) {
            // Account selector
            HStack {
                AccountSelectorView()
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Scan button (inline on iPhone only)
            if sizeClass == .compact {
                Button {
                    showCapture = true
                } label: {
                    Label("Scan Receipt", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppConstants.Colors.primaryAccent)
                .disabled(account.accountRole?.canUpload != true)
                .padding(.horizontal)
                .padding(.bottom, 4)

                if account.accountRole?.canUpload != true {
                    Text("Viewers cannot upload receipts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }

                Divider()
                    .padding(.top, 8)
            }

            // Receipt list
            ReceiptListView(accountId: account.id, selectedReceipt: $selectedReceipt)
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
}
