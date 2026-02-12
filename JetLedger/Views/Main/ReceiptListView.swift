//
//  ReceiptListView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftData
import SwiftUI

struct ReceiptListView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var selectedReceipt: LocalReceipt?
    @Query private var receipts: [LocalReceipt]

    init(accountId: UUID, selectedReceipt: Binding<LocalReceipt?>) {
        _selectedReceipt = selectedReceipt
        _receipts = Query(
            filter: #Predicate<LocalReceipt> { receipt in
                receipt.accountId == accountId
            },
            sort: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
    }

    var body: some View {
        if receipts.isEmpty {
            ContentUnavailableView {
                Label("No Receipts Yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Tap Scan Receipt to capture your first receipt.")
            }
        } else {
            List(receipts, id: \.id, selection: sizeClass == .regular ? selectionBinding : nil) { receipt in
                if sizeClass == .compact {
                    NavigationLink {
                        ReceiptDetailView(receipt: receipt)
                    } label: {
                        ReceiptRowView(receipt: receipt)
                    }
                    .swipeActions(edge: .trailing) {
                        retryButton(for: receipt)
                    }
                } else {
                    ReceiptRowView(receipt: receipt)
                        .tag(receipt)
                        .swipeActions(edge: .trailing) {
                            retryButton(for: receipt)
                        }
                }
            }
            .listStyle(.plain)
            .refreshable {
                syncService.processQueue()
                await syncService.syncReceiptStatuses()
            }
        }
    }

    private var selectionBinding: Binding<LocalReceipt?> {
        Binding(
            get: { selectedReceipt },
            set: { selectedReceipt = $0 }
        )
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
