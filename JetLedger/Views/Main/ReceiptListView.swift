//
//  ReceiptListView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftData
import SwiftUI

struct ReceiptListView<Header: View>: View {
    @Environment(SyncService.self) private var syncService
    @Environment(AccountService.self) private var accountService
    @Environment(ReceiptListService.self) private var receiptListService
    @Binding var selectedReceipt: LocalReceipt?
    @Query private var receipts: [LocalReceipt]
    private let accountId: UUID
    private let header: Header

    init(accountId: UUID, selectedReceipt: Binding<LocalReceipt?>, @ViewBuilder header: () -> Header) {
        self.accountId = accountId
        _selectedReceipt = selectedReceipt
        _receipts = Query(
            filter: #Predicate<LocalReceipt> { receipt in
                receipt.accountId == accountId && receipt.dismissedAt == nil
            },
            sort: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        self.header = header()
    }

    /// Receipts that exist only on this phone. They are actionable — retry,
    /// manage pages — and nothing else knows about them, so they pin to the top.
    /// A row leaves this section the moment it gets a server id.
    private var onDeviceReceipts: [LocalReceipt] {
        receipts.filter { $0.serverReceiptId == nil }
    }

    /// Everything the server knows about, in the order the server returns it.
    private var historyReceipts: [LocalReceipt] {
        receipts.filter { $0.serverReceiptId != nil }
    }

    private var stalledReceipts: [LocalReceipt] {
        receipts.filter(\.isStalled)
    }

    var body: some View {
        List(selection: $selectedReceipt) {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if !stalledReceipts.isEmpty {
                stalledBanner
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if receipts.isEmpty {
                if let loadError = receiptListService.loadError {
                    // An empty mirror plus a failed fetch is not "no receipts" —
                    // saying so would be a lie the user acts on.
                    ContentUnavailableView {
                        Label("Couldn't Load Receipts", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            Task { await receiptListService.refresh(accountId: accountId) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(.brandPrimary))
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView {
                        Label("No Receipts Yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Tap Scan Receipt to capture your first receipt.")
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            } else {
                if !onDeviceReceipts.isEmpty {
                    Section {
                        ForEach(onDeviceReceipts) { receipt in
                            ReceiptRowView(receipt: receipt)
                                .tag(receipt)
                                .swipeActions(edge: .trailing) {
                                    retryButton(for: receipt)
                                }
                        }
                    } header: {
                        Text("On This Device")
                    }
                }

                if !historyReceipts.isEmpty {
                    Section {
                        ForEach(historyReceipts) { receipt in
                            ReceiptRowView(receipt: receipt)
                                .tag(receipt)
                                .swipeActions(edge: .trailing) {
                                    dismissButton(for: receipt)
                                    retryButton(for: receipt)
                                }
                                .onAppear {
                                    // Infinite scroll: the last row appearing is
                                    // the trigger. loadNextPage swallows repeat
                                    // calls while a page is in flight.
                                    if receipt.id == historyReceipts.last?.id {
                                        Task { await receiptListService.loadNextPage(accountId: accountId) }
                                    }
                                }
                        }
                    }
                }

                if receiptListService.isLoadingPage {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            syncService.processQueue()
            await accountService.refreshAccounts()
            await syncService.syncReceiptStatuses()
            // Capture before the refresh so the check never reads a deleted model.
            let selectedId = selectedReceipt?.id
            let pruned = await receiptListService.refresh(accountId: accountId)
            syncService.performCleanup()
            if let selectedId, pruned.contains(selectedId) {
                selectedReceipt = nil
            }
        }
    }

    /// A receipt stuck for over a day is not a passing network blip, and the
    /// per-row "Failed" badge never escalates to say so. Without this, a receipt
    /// that will never upload on its own looks exactly like one that is about to.
    private var stalledBanner: some View {
        let count = stalledReceipts.count
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                count == 1
                    ? "1 receipt hasn't uploaded"
                    : "\(count) receipts haven't uploaded",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(.statusWarningContent))

            Text("They've been retrying for more than a day. They're still saved on this device — tap to try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Retry All") {
                syncService.retryAllFailed()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.statusWarning).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    /// Rejected receipts are dead weight once seen. Dismissing hides the row on
    /// this device only — the server record stays for admin review on the web,
    /// and `dismissedAt` is persisted so the next page fetch doesn't bring it
    /// straight back.
    @ViewBuilder
    private func dismissButton(for receipt: LocalReceipt) -> some View {
        if receipt.serverStatus == .rejected {
            Button(role: .destructive) {
                if selectedReceipt == receipt {
                    selectedReceipt = nil
                }
                syncService.dismissRejectedReceipt(receipt)
            } label: {
                Label("Dismiss", systemImage: "eye.slash")
            }
        }
    }

    @ViewBuilder
    private func retryButton(for receipt: LocalReceipt) -> some View {
        if receipt.syncStatus == .failed {
            Button {
                syncService.retryReceipt(receipt)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .tint(Color(.brandPrimary))
        }
    }
}
