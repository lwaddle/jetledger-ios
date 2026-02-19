//
//  SharedImportService.swift
//  JetLedger
//

import Foundation
import SwiftData
import UIKit

enum SharedImportService {

    /// Checks the shared container for pending imports and creates LocalReceipt records.
    /// Returns the number of imports processed.
    @discardableResult
    static func processPendingImports(accountId: UUID, modelContext: ModelContext) -> Int {
        let manifest = SharedContainerHelper.loadManifest()
        guard !manifest.isEmpty else { return 0 }

        var processedCount = 0

        for pendingImport in manifest {
            let receiptId = UUID()
            var receiptPages: [LocalReceiptPage] = []

            for (index, file) in pendingImport.files.enumerated() {
                guard let data = SharedContainerHelper.loadFileData(relativePath: file.relativePath) else {
                    continue
                }

                let contentType = PageContentType(rawValue: file.contentType) ?? .jpeg

                switch contentType {
                case .pdf:
                    guard let relativePath = ImageUtils.saveReceiptPDF(
                        data: data,
                        receiptId: receiptId,
                        pageIndex: index
                    ) else { continue }

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
                    guard let image = UIImage(data: data) else { continue }
                    let resized = ImageUtils.resizeIfNeeded(image)
                    guard let jpegData = ImageUtils.compressToJPEG(resized) else { continue }

                    guard let relativePath = ImageUtils.saveReceiptImage(
                        data: jpegData,
                        receiptId: receiptId,
                        pageIndex: index
                    ) else { continue }

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
                SharedContainerHelper.removeImport(id: pendingImport.id)
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

            SharedContainerHelper.removeImport(id: pendingImport.id)
            processedCount += 1
        }

        if processedCount > 0 {
            try? modelContext.save()
        }

        return processedCount
    }
}
