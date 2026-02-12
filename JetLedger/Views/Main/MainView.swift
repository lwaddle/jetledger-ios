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
    @State private var showCapture = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if accountService.isLoading {
                    Spacer()
                    ProgressView("Loading accounts...")
                    Spacer()
                } else if let account = accountService.selectedAccount {
                    accountContent(account)
                } else {
                    Spacer()
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "building.2",
                        description: Text("You don't belong to any accounts. Contact your administrator.")
                    )
                    Spacer()
                }
            }
            .navigationTitle("JetLedger")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
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
            .task {
                syncService.processQueue()
                await syncService.syncReceiptStatuses()
                if let accountId = accountService.selectedAccount?.id {
                    await tripReferenceService.loadTripReferences(for: accountId)
                }
            }
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

            // Scan button
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

            // Receipt list
            ReceiptListView(accountId: account.id)
        }
    }
}
