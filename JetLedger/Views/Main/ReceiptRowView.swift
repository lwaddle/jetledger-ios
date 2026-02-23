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

                    if receipt.tripReferenceExternalId != nil || receipt.tripReferenceName != nil {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let tripId = receipt.tripReferenceExternalId {
                            Text("Trip \(tripId)")
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundStyle(.secondary)
                        } else if let tripName = receipt.tripReferenceName {
                            Text(tripName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SyncStatusBadge(
                    syncStatus: receipt.syncStatus,
                    serverStatus: receipt.serverStatus
                )
            }

            Spacer()

            HStack(spacing: 4) {
                if receipt.pages.contains(where: { $0.contentType == .pdf }) {
                    Text("PDF")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.indigo.opacity(0.12), in: Capsule())
                        .foregroundStyle(.indigo)
                }
                if receipt.pages.count > 1 {
                    Text("\(receipt.pages.count) pages")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
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
               let image = ImageUtils.loadReceiptImage(relativePath: thumbnailPath(for: firstPage.localImagePath)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: thumbnailIcon)
                            .foregroundStyle(.secondary)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }

    private var thumbnailIcon: String {
        if receipt.imagesCleanedUp {
            return "clock.badge.checkmark"
        } else if receipt.isRemote && receipt.pages.contains(where: { !$0.imageDownloaded }) {
            return "icloud.and.arrow.down"
        } else {
            return "doc.fill"
        }
    }

    private func thumbnailPath(for imagePath: String) -> String {
        ImageUtils.thumbnailPath(for: imagePath)
    }
}
