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
    @Binding var selectedReceipt: LocalReceipt?
    @Query private var receipts: [LocalReceipt]
    @State private var showAllCompleted = false
    private let accountId: UUID
    private let header: Header

    init(accountId: UUID, selectedReceipt: Binding<LocalReceipt?>, @ViewBuilder header: () -> Header) {
        self.accountId = accountId
        _selectedReceipt = selectedReceipt
        _receipts = Query(
            filter: #Predicate<LocalReceipt> { receipt in
                receipt.accountId == accountId
            },
            sort: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        self.header = header()
    }

    private var activeReceipts: [LocalReceipt] {
        receipts.filter { receipt in
            receipt.serverStatus != .processed && receipt.serverStatus != .rejected
        }
    }

    private var completedReceipts: [LocalReceipt] {
        receipts.filter { receipt in
            receipt.serverStatus == .processed || receipt.serverStatus == .rejected
        }
    }

    private var visibleCompleted: [LocalReceipt] {
        if showAllCompleted { return completedReceipts }
        return Array(completedReceipts.prefix(5))
    }

    private var hiddenCompletedCount: Int {
        showAllCompleted ? 0 : max(0, completedReceipts.count - 5)
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
                ContentUnavailableView {
                    Label("No Receipts Yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Tap Scan Receipt to capture your first receipt.")
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                if !activeReceipts.isEmpty {
                    Section {
                        ForEach(activeReceipts) { receipt in
                            ReceiptRowView(receipt: receipt)
                                .tag(receipt)
                                .swipeActions(edge: .trailing) {
                                    retryButton(for: receipt)
                                }
                        }
                    }
                }

                if !completedReceipts.isEmpty {
                    Section {
                        ForEach(visibleCompleted) { receipt in
                            ReceiptRowView(receipt: receipt)
                                .tag(receipt)
                                .swipeActions(edge: .trailing) {
                                    removeButton(for: receipt)
                                    retryButton(for: receipt)
                                }
                        }

                        if hiddenCompletedCount > 0 {
                            Button {
                                withAnimation {
                                    showAllCompleted = true
                                }
                            } label: {
                                Text("Show \(hiddenCompletedCount) older")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                    } header: {
                        Text("Completed")
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            syncService.processQueue()
            await accountService.refreshAccounts()
            await syncService.syncReceiptStatuses()
            // Capture before cleanup so the check never reads a deleted model.
            let selectedId = selectedReceipt?.id
            let deletedIds = syncService.performCleanup()
            if let selectedId, deletedIds.contains(selectedId) {
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

    /// Rejected receipts are dead weight once seen — swiping removes them from
    /// this device only; the server record stays for admin review on the web.
    @ViewBuilder
    private func removeButton(for receipt: LocalReceipt) -> some View {
        if receipt.serverStatus == .rejected {
            Button(role: .destructive) {
                if selectedReceipt == receipt {
                    selectedReceipt = nil
                }
                syncService.removeRejectedReceiptLocally(receipt)
            } label: {
                Label("Remove", systemImage: "trash")
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
