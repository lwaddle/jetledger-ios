//
//  ImportFlowCoordinator.swift
//  JetLedger
//

import SwiftData
import UIKit
import UniformTypeIdentifiers

struct ImportedFile: Identifiable {
    let id = UUID()
    let data: Data
    let contentType: PageContentType
    let originalFileName: String
    var thumbnail: UIImage?
}

@Observable
class ImportFlowCoordinator {
    var currentStep: ImportStep = .preview
    var files: [ImportedFile] = []
    var splitIntoSeparateReceipts: Bool = true
    var isSaving = false
    var error: String?

    let accountId: UUID
    let modelContext: ModelContext

    init(accountId: UUID, modelContext: ModelContext) {
        self.accountId = accountId
        self.modelContext = modelContext
    }

    // MARK: - File Handling

    func handleImportedURLs(_ urls: [URL]) {
        var imported: [ImportedFile] = []

        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url) else { continue }

            let fileName = url.lastPathComponent
            let uti = UTType(filenameExtension: url.pathExtension)

            if uti?.conforms(to: .pdf) == true {
                guard data.count <= AppConstants.PDF.maxFileSize else { continue }
                let thumbnail = ImageUtils.renderPDFThumbnail(
                    pdfData: data,
                    size: CGSize(width: 120, height: 160)
                )
                imported.append(ImportedFile(
                    data: data,
                    contentType: .pdf,
                    originalFileName: fileName,
                    thumbnail: thumbnail
                ))
            } else if uti?.conforms(to: .image) == true {
                guard data.count <= AppConstants.Image.maxFileSize else { continue }
                let thumbnail = UIImage(data: data).flatMap { img in
                    let size = CGSize(width: 120, height: 160)
                    let renderer = UIGraphicsImageRenderer(size: size)
                    return renderer.image { _ in
                        let scale = max(size.width / img.size.width, size.height / img.size.height)
                        let scaledSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                        let origin = CGPoint(
                            x: (size.width - scaledSize.width) / 2,
                            y: (size.height - scaledSize.height) / 2
                        )
                        img.draw(in: CGRect(origin: origin, size: scaledSize))
                    }
                }
                imported.append(ImportedFile(
                    data: data,
                    contentType: .jpeg,
                    originalFileName: fileName,
                    thumbnail: thumbnail
                ))
            }
        }

        files = imported
        if !imported.isEmpty {
            currentStep = .preview
        }
    }

    // MARK: - Save

    func saveReceipt(
        note: String?,
        tripReferenceId: UUID?,
        tripReferenceExternalId: String?,
        tripReferenceName: String?
    ) async -> Int {
        guard !files.isEmpty else { return 0 }
        isSaving = true
        defer { isSaving = false }

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = (trimmedNote?.isEmpty == false) ? trimmedNote : nil

        if splitIntoSeparateReceipts && files.count > 1 {
            var savedCount = 0
            for file in files {
                if saveOneSingleFileReceipt(
                    file: file,
                    note: finalNote,
                    tripReferenceId: tripReferenceId,
                    tripReferenceExternalId: tripReferenceExternalId,
                    tripReferenceName: tripReferenceName
                ) {
                    savedCount += 1
                }
            }

            if savedCount == 0 {
                error = "Failed to save imported files."
                return 0
            }

            do {
                try modelContext.save()
                return savedCount
            } catch {
                self.error = "Failed to save receipts: \(error.localizedDescription)"
                return 0
            }
        }

        // Combined path (today's behavior): one receipt with N pages.
        let receiptId = UUID()
        var receiptPages: [LocalReceiptPage] = []

        for (index, file) in files.enumerated() {
            if let page = persistPage(file: file, receiptId: receiptId, pageIndex: index) {
                receiptPages.append(page)
            }
        }

        guard !receiptPages.isEmpty else {
            error = "Failed to save imported files."
            return 0
        }

        let receipt = LocalReceipt(
            id: receiptId,
            accountId: accountId,
            note: finalNote,
            tripReferenceId: tripReferenceId,
            tripReferenceExternalId: tripReferenceExternalId,
            tripReferenceName: tripReferenceName,
            capturedAt: Date(),
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
            return 1
        } catch {
            self.error = "Failed to save receipt: \(error.localizedDescription)"
            return 0
        }
    }

    // MARK: - Persistence helpers (private)

    private func saveOneSingleFileReceipt(
        file: ImportedFile,
        note: String?,
        tripReferenceId: UUID?,
        tripReferenceExternalId: String?,
        tripReferenceName: String?
    ) -> Bool {
        let receiptId = UUID()
        guard let page = persistPage(file: file, receiptId: receiptId, pageIndex: 0) else {
            return false
        }

        let receipt = LocalReceipt(
            id: receiptId,
            accountId: accountId,
            note: note,
            tripReferenceId: tripReferenceId,
            tripReferenceExternalId: tripReferenceExternalId,
            tripReferenceName: tripReferenceName,
            capturedAt: Date(),
            enhancementMode: .original,
            syncStatus: .queued,
            pages: [page]
        )

        modelContext.insert(receipt)
        page.receipt = receipt
        modelContext.insert(page)
        return true
    }

    private func persistPage(
        file: ImportedFile,
        receiptId: UUID,
        pageIndex: Int
    ) -> LocalReceiptPage? {
        switch file.contentType {
        case .pdf:
            guard let relativePath = ImageUtils.saveReceiptPDF(
                data: file.data,
                receiptId: receiptId,
                pageIndex: pageIndex
            ) else { return nil }

            _ = ImageUtils.savePDFThumbnail(
                pdfData: file.data,
                receiptId: receiptId,
                pageIndex: pageIndex
            )

            return LocalReceiptPage(
                sortOrder: pageIndex,
                localImagePath: relativePath,
                contentType: .pdf
            )

        case .jpeg:
            guard let image = UIImage(data: file.data) else { return nil }
            let resized = ImageUtils.resizeIfNeeded(image)
            guard let jpegData = ImageUtils.compressToJPEG(resized) else { return nil }

            guard let relativePath = ImageUtils.saveReceiptImage(
                data: jpegData,
                receiptId: receiptId,
                pageIndex: pageIndex
            ) else { return nil }

            _ = ImageUtils.saveThumbnail(
                from: resized,
                receiptId: receiptId,
                pageIndex: pageIndex
            )

            return LocalReceiptPage(
                sortOrder: pageIndex,
                localImagePath: relativePath,
                contentType: .jpeg
            )
        }
    }
}
