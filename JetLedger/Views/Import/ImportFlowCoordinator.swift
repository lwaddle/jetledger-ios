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
    var currentStep: ImportStep = .filePicker
    var files: [ImportedFile] = []
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
    ) async -> LocalReceipt? {
        guard !files.isEmpty else { return nil }
        isSaving = true
        defer { isSaving = false }

        let receiptId = UUID()
        var receiptPages: [LocalReceiptPage] = []

        for (index, file) in files.enumerated() {
            switch file.contentType {
            case .pdf:
                guard let relativePath = ImageUtils.saveReceiptPDF(
                    data: file.data,
                    receiptId: receiptId,
                    pageIndex: index
                ) else { continue }

                _ = ImageUtils.savePDFThumbnail(
                    pdfData: file.data,
                    receiptId: receiptId,
                    pageIndex: index
                )

                receiptPages.append(LocalReceiptPage(
                    sortOrder: index,
                    localImagePath: relativePath,
                    contentType: .pdf
                ))

            case .jpeg:
                guard let image = UIImage(data: file.data) else { continue }
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
            error = "Failed to save imported files."
            return nil
        }

        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        let receipt = LocalReceipt(
            id: receiptId,
            accountId: accountId,
            note: trimmedNote?.isEmpty == false ? trimmedNote : nil,
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
        } catch {
            self.error = "Failed to save receipt: \(error.localizedDescription)"
            return nil
        }

        return receipt
    }
}
