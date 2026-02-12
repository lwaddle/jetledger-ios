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
    @Query private var receipts: [LocalReceipt]

    init(accountId: UUID) {
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
            List(receipts, id: \.id) { receipt in
                ReceiptRowView(receipt: receipt)
                    .swipeActions(edge: .trailing) {
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
            .listStyle(.plain)
            .refreshable {
                syncService.processQueue()
                await syncService.syncReceiptStatuses()
            }
        }
    }
}
