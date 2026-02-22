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
    @Binding var selectedReceipt: LocalReceipt?
    @Query private var receipts: [LocalReceipt]
    @State private var showAllCompleted = false
    private let header: Header

    init(accountId: UUID, selectedReceipt: Binding<LocalReceipt?>, @ViewBuilder header: () -> Header) {
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

    var body: some View {
        List(selection: $selectedReceipt) {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

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
            await syncService.syncReceiptStatuses()
            syncService.performCleanup()
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
            .tint(.blue)
        }
    }
}
