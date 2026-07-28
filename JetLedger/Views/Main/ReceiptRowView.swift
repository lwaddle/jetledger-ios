//
//  ReceiptRowView.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct ReceiptRowView: View {
    let receipt: LocalReceipt

    @Environment(TripReferenceService.self) private var tripReferenceService

    var body: some View {
        HStack(spacing: 12) {
            ReceiptThumbnail(receipt: receipt)

            VStack(alignment: .leading, spacing: 3) {
                Text(ReceiptDateFormatter.rowTitle(for: receipt.capturedAt))
                    .font(.headline)
                    .lineLimit(1)

                if let note = receipt.note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let tripLabel {
                    Text(tripLabel)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                SyncStatusBadge(
                    syncStatus: receipt.syncStatus,
                    serverStatus: receipt.serverStatus,
                    compactWhenProcessed: true
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var tripLabel: String? {
        ReceiptRowFormatting.tripLabel(
            externalId: receipt.tripReferenceExternalId,
            name: receipt.tripReferenceName,
            tripReferenceId: receipt.tripReferenceId,
            cache: tripReferenceService.tripReferences
        )
    }
}

// MARK: - Thumbnail

private struct ReceiptThumbnail: View {
    let receipt: LocalReceipt

    private static let size = CGSize(width: 45, height: 60)

    var body: some View {
        Group {
            if let firstPage = sortedPages.first,
               let image = ImageUtils.loadReceiptImage(relativePath: ImageUtils.thumbnailPath(for: firstPage.localImagePath)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .overlay {
                        Image(systemName: placeholderIcon)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(2)
            }
        }
    }

    private var sortedPages: [LocalReceiptPage] {
        receipt.pages.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Page count wins over the PDF tag on multi-page receipts — "how much is
    /// here" matters more in the list than the file format. A multi-page PDF
    /// is one page record, so its internal count is surfaced as "PDF·N".
    private var badge: String? {
        // A mirrored row has no page records until its detail is fetched, so the
        // server's count is the only thing that knows there is more than one.
        let count = receipt.pages.isEmpty ? receipt.imageCount : receipt.pages.count
        if count > 1 {
            return "\(count)"
        }
        if let pdfPage = receipt.pages.first(where: { $0.contentType == .pdf }) {
            if let pageCount = ImageUtils.pdfPageCount(relativePath: pdfPage.localImagePath),
               pageCount > 1 {
                return "PDF·\(pageCount)"
            }
            return "PDF"
        }
        return nil
    }

    private var placeholderIcon: String {
        ReceiptRowFormatting.placeholderIcon(
            source: receipt.source,
            imagesCleanedUp: receipt.imagesCleanedUp
        )
    }
}
