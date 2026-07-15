//
//  SharedImportService.swift
//  JetLedger
//

import Foundation
import SwiftData
import UIKit

enum SharedImportService {

    struct ImportResult {
        let imported: Int
        let failed: Int
        /// Pages dropped from receipts that otherwise imported (corrupt data,
        /// oversized PDF, disk write failure). The receipt still imports; the
        /// user must be told it is incomplete.
        let pagesDropped: Int

        /// User-facing description of anything that went wrong, or nil if clean.
        var problemMessage: String? {
            var parts: [String] = []
            if failed > 0 {
                parts.append("\(failed) shared \(failed == 1 ? "import" : "imports") could not be processed.")
            }
            if pagesDropped > 0 {
                parts.append("\(pagesDropped) \(pagesDropped == 1 ? "page" : "pages") could not be imported and \(pagesDropped == 1 ? "was" : "were") skipped.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Checks the shared container for pending imports and creates LocalReceipt records.
    /// Returns counts of successful and failed imports.
    ///
    /// Ordering matters: the shared-container source files are the only copy of the
    /// user's data until the SwiftData save succeeds, so each import is persisted
    /// (per-receipt save) BEFORE its manifest entry and source files are removed.
    /// A save failure leaves the manifest entry in place for the next foreground.
    @discardableResult
    static func processPendingImports(accountId: UUID, modelContext: ModelContext) -> ImportResult {
        let manifest = SharedContainerHelper.loadManifest()
        guard !manifest.isEmpty else { return ImportResult(imported: 0, failed: 0, pagesDropped: 0) }

        var processedCount = 0
        var failedCount = 0
        var droppedPageCount = 0

        for pendingImport in manifest {
            let receiptId = UUID()
            var receiptPages: [LocalReceiptPage] = []
            var droppedPages = 0

            for (index, file) in pendingImport.files.enumerated() {
                guard let data = SharedContainerHelper.loadFileData(relativePath: file.relativePath) else {
                    droppedPages += 1
                    continue
                }

                let contentType = PageContentType(rawValue: file.contentType) ?? .jpeg

                switch contentType {
                case .pdf:
                    // PDFs are stored verbatim — an oversized one would be queued
                    // and then permanently rejected by the upload endpoint (413),
                    // so reject it here where the user can still be told.
                    guard data.count <= AppConstants.PDF.maxFileSize,
                          let relativePath = ImageUtils.saveReceiptPDF(
                            data: data,
                            receiptId: receiptId,
                            pageIndex: index
                          ) else {
                        droppedPages += 1
                        continue
                    }

                    _ = ImageUtils.savePDFThumbnail(
                        pdfData: data,
                        receiptId: receiptId,
                        pageIndex: index
                    )

                    receiptPages.append(LocalReceiptPage(
                        sortOrder: index,
                        localImagePath: relativePath,
                        contentType: .pdf
                    ))

                case .jpeg:
                    guard let image = UIImage(data: data) else {
                        droppedPages += 1
                        continue
                    }
                    let resized = ImageUtils.resizeIfNeeded(image)
                    guard let jpegData = ImageUtils.compressToJPEG(resized),
                          let relativePath = ImageUtils.saveReceiptImage(
                            data: jpegData,
                            receiptId: receiptId,
                            pageIndex: index
                          ) else {
                        droppedPages += 1
                        continue
                    }

                    _ = ImageUtils.saveThumbnail(
                        from: resized,
                        receiptId: receiptId,
                        pageIndex: index
                    )

                    receiptPages.append(LocalReceiptPage(
                        sortOrder: index,
                        localImagePath: relativePath,
                        contentType: .jpeg
                    ))
                }
            }

            guard !receiptPages.isEmpty else {
                // Nothing usable in this import — remove it so it doesn't retry
                // forever, and report the failure.
                ImageUtils.deleteReceiptImages(receiptId: receiptId)
                SharedContainerHelper.removeImport(id: pendingImport.id)
                failedCount += 1
                droppedPageCount += droppedPages
                continue
            }

            let receipt = LocalReceipt(
                id: receiptId,
                accountId: accountId,
                capturedAt: pendingImport.createdAt,
                enhancementMode: .original,
                syncStatus: .queued,
                pages: receiptPages
            )

            modelContext.insert(receipt)
            for page in receiptPages {
                page.receipt = receipt
                modelContext.insert(page)
            }

            do {
                try modelContext.save()
            } catch {
                // Undo this receipt's inserts and its written files; keep the
                // manifest entry (and source files) so the next foreground retries.
                modelContext.rollback()
                ImageUtils.deleteReceiptImages(receiptId: receiptId)
                failedCount += 1
                continue
            }

            // Only now is the import durable — safe to destroy the source files.
            SharedContainerHelper.removeImport(id: pendingImport.id)
            processedCount += 1
            droppedPageCount += droppedPages
        }

        return ImportResult(imported: processedCount, failed: failedCount, pagesDropped: droppedPageCount)
    }
}
