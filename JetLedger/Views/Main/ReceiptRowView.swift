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
            // Thumbnail
            ReceiptThumbnail(receipt: receipt)

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

// MARK: - Thumbnail

private struct ReceiptThumbnail: View {
    let receipt: LocalReceipt

    var body: some View {
        Group {
            if let firstPage = receipt.pages.sorted(by: { $0.sortOrder < $1.sortOrder }).first,
               let thumbPath = thumbnailPath(for: firstPage.localImagePath),
               let image = ImageUtils.loadReceiptImage(relativePath: thumbPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func thumbnailPath(for imagePath: String) -> String? {
        // page-001.jpg -> page-001-thumb.jpg
        guard let dotIndex = imagePath.lastIndex(of: ".") else { return nil }
        return String(imagePath[imagePath.startIndex..<dotIndex]) + "-thumb" + String(imagePath[dotIndex...])
    }
}
