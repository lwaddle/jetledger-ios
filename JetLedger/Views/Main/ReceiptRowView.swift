//
//  ReceiptRowView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct ReceiptRowView: View {
    let receipt: LocalReceipt

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.note ?? "No note")
                    .font(.body)
                    .foregroundStyle(receipt.note != nil ? .primary : .secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(receipt.capturedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let tripId = receipt.tripReferenceExternalId {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Trip \(tripId)")
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                }

                SyncStatusBadge(
                    syncStatus: receipt.syncStatus,
                    serverStatus: receipt.serverStatus
                )
            }

            Spacer()

            if receipt.pages.count > 1 {
                Text("\(receipt.pages.count)pp")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}
