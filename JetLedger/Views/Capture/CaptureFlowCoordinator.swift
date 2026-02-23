//
//  CaptureFlowCoordinator.swift
//  JetLedger
//

import SwiftData
import UIKit

struct CapturedPage: Identifiable {
    let id = UUID()
    var originalImage: CGImage?
    var detectedCorners: DetectedRectangle?
    var processedImage: UIImage?
    var enhancementMode: EnhancementMode
    var exposureLevel: ExposureLevel = .zero
}

@Observable
class CaptureFlowCoordinator {
    var currentStep: CaptureStep = .camera
    var pages: [CapturedPage] = []
    var currentCapture: CapturedPage?
    var flashMode: FlashMode = .auto
    var isSaving = false
    var isProcessing = false
    var processingFailed = false
    var error: String?

    let accountId: UUID
    let defaultEnhancementMode: EnhancementMode
    let imageProcessor: ImageProcessor
    let modelContext: ModelContext

    init(
        accountId: UUID,
        defaultEnhancementMode: EnhancementMode,
        imageProcessor: ImageProcessor,
        modelContext: ModelContext
    ) {
        self.accountId = accountId
        self.defaultEnhancementMode = defaultEnhancementMode
        self.imageProcessor = imageProcessor
        self.modelContext = modelContext
    }

    // MARK: - Capture Handling

    func handleCapturedImage(_ cgImage: CGImage) {
        isProcessing = true
        processingFailed = false
        let processor = imageProcessor
        let mode = currentCapture?.enhancementMode ?? defaultEnhancementMode

        Task.detached { [self, mode] in
            let corners = processor.detectRectangle(in: cgImage)
            let processed = processor.processCapture(
                image: cgImage,
                corners: corners,
                enhancement: mode
            )

            await MainActor.run {
                let fallback = processed ?? UIImage(cgImage: cgImage)
                self.processingFailed = (processed == nil)
                self.currentCapture = CapturedPage(
                    originalImage: cgImage,
                    detectedCorners: corners,
                    processedImage: fallback,
                    enhancementMode: mode
                )
                self.isProcessing = false
                self.currentStep = .preview
            }
        }
    }

    // MARK: - Enhancement

    func changeEnhancement(to mode: EnhancementMode) {
        guard var capture = currentCapture, let cgImage = capture.originalImage else { return }
        capture.enhancementMode = mode
        currentCapture = capture
        isProcessing = true
        processingFailed = false

        let processor = imageProcessor
        let corners = capture.detectedCorners
        let ev = capture.exposureLevel.evValue

        Task.detached { [self, mode] in
            let processed = processor.processCapture(
                image: cgImage,
                corners: corners,
                enhancement: mode,
                exposureEV: ev
            )

            await MainActor.run {
                if var current = self.currentCapture {
                    current.processedImage = processed ?? UIImage(cgImage: cgImage)
                    current.enhancementMode = mode
                    self.currentCapture = current
                    self.processingFailed = (processed == nil)
                }
                self.isProcessing = false
            }
        }
    }

    func changeExposure(to level: ExposureLevel) {
        guard var capture = currentCapture, let cgImage = capture.originalImage else { return }
        capture.exposureLevel = level
        currentCapture = capture
        isProcessing = true
        processingFailed = false

        let processor = imageProcessor
        let corners = capture.detectedCorners
        let mode = capture.enhancementMode
        let ev = level.evValue

        Task.detached { [self] in
            let processed = processor.processCapture(
                image: cgImage,
                corners: corners,
                enhancement: mode,
                exposureEV: ev
            )

            await MainActor.run {
                if var current = self.currentCapture {
                    current.processedImage = processed ?? UIImage(cgImage: cgImage)
                    current.exposureLevel = level
                    self.currentCapture = current
                    self.processingFailed = (processed == nil)
                }
                self.isProcessing = false
            }
        }
    }

    // MARK: - Corner Adjustment

    func updateCorners(_ corners: DetectedRectangle) {
        guard var capture = currentCapture, let cgImage = capture.originalImage else { return }
        capture.detectedCorners = corners
        currentCapture = capture
        isProcessing = true
        processingFailed = false

        let processor = imageProcessor
        let mode = capture.enhancementMode
        let ev = capture.exposureLevel.evValue

        Task.detached { [self] in
            let processed = processor.processCapture(
                image: cgImage,
                corners: corners,
                enhancement: mode,
                exposureEV: ev
            )

            await MainActor.run {
                if var current = self.currentCapture {
                    current.processedImage = processed ?? UIImage(cgImage: cgImage)
                    current.detectedCorners = corners
                    self.currentCapture = current
                    self.processingFailed = (processed == nil)
                }
                self.isProcessing = false
                self.currentStep = .preview
            }
        }
    }

    // MARK: - Page Management

    func acceptCurrentPage() {
        guard let capture = currentCapture else { return }
        pages.append(capture)
        currentCapture = nil
        currentStep = .multiPagePrompt
    }

    func addAnotherPage() {
        currentCapture = nil
        currentStep = .camera
    }

    func retake() {
        currentCapture = nil
        currentStep = .camera
    }

    func openCropAdjust() {
        currentStep = .cropAdjust
    }

    // MARK: - Metadata

    func proceedToMetadata() {
        currentStep = .metadata
    }

    func returnToMultiPagePrompt() {
        currentStep = .multiPagePrompt
    }

    // MARK: - Save

    func saveReceipt(
        note: String?,
        tripReferenceId: UUID?,
        tripReferenceExternalId: String?,
        tripReferenceName: String?
    ) async -> LocalReceipt? {
        guard !pages.isEmpty else { return nil }
        isSaving = true
        defer { isSaving = false }

        let receiptId = UUID()
        let enhancement = pages.first?.enhancementMode ?? defaultEnhancementMode
        var receiptPages: [LocalReceiptPage] = []

        for index in pages.indices {
            guard let processed = pages[index].processedImage else { continue }

            let resized = ImageUtils.resizeIfNeeded(processed)
            guard let jpegData = ImageUtils.compressToJPEG(resized) else { continue }

            guard let relativePath = ImageUtils.saveReceiptImage(
                data: jpegData,
                receiptId: receiptId,
                pageIndex: index
            ) else { continue }

            // Save thumbnail
            _ = ImageUtils.saveThumbnail(
                from: resized,
                receiptId: receiptId,
                pageIndex: index
            )

            let receiptPage = LocalReceiptPage(
                sortOrder: index,
                localImagePath: relativePath
            )
            receiptPages.append(receiptPage)

            // Release memory after successful disk write
            pages[index].originalImage = nil
            pages[index].processedImage = nil
        }

        guard !receiptPages.isEmpty else {
            error = "Failed to save receipt images."
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
            enhancementMode: enhancement,
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
