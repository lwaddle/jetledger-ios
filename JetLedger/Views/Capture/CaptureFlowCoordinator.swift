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

    func handleCapturedImage(_ cgImage: CGImage, fallbackCorners: DetectedRectangle? = nil) {
        isProcessing = true
        processingFailed = false
        let processor = imageProcessor
        let mode = currentCapture?.enhancementMode ?? defaultEnhancementMode

        Task.detached { [self, mode] in
            // Still-image detection can fail where the live feed had a lock
            // (flash glare, capture blur) — fall back to the rect the user was
            // looking at when they pressed the shutter.
            let corners = processor.detectRectangle(in: cgImage) ?? fallbackCorners
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

    /// Reprocessing tasks are unordered (Task.detached) — rapid mode/exposure
    /// taps can complete out of order, leaving an earlier request's image as
    /// the final state and clearing the spinner while a job is still running.
    /// Each request bumps the generation; only the newest may apply its result.
    private var processingGeneration = 0

    func changeEnhancement(to mode: EnhancementMode) {
        guard var capture = currentCapture, let cgImage = capture.originalImage else { return }
        capture.enhancementMode = mode
        currentCapture = capture
        isProcessing = true
        processingFailed = false
        processingGeneration += 1
        let generation = processingGeneration

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
                guard generation == self.processingGeneration else { return }
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
        processingGeneration += 1
        let generation = processingGeneration

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
                guard generation == self.processingGeneration else { return }
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
        processingGeneration += 1
        let generation = processingGeneration

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
                guard generation == self.processingGeneration else { return }
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

    private func acceptCurrentPage() {
        guard var capture = currentCapture else { return }
        // Accepted pages are never re-processed, so the full-resolution source
        // CGImage (~48MB at 12MP) is dead weight from here on. Without this, a
        // 4-6 page receipt holds two full-res bitmaps per page until save and
        // gets jetsam-killed on lower-RAM devices — losing every page, since
        // nothing hits disk until save.
        capture.originalImage = nil
        pages.append(capture)
        currentCapture = nil
    }

    func acceptPageAndAddAnother() {
        acceptCurrentPage()
        currentStep = .camera
    }

    func acceptPageAndContinue() {
        acceptCurrentPage()
        currentStep = .metadata
    }

    /// From metadata's "Add Page" — no capture in flight to accept.
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

    /// The metadata view is recreated when the user hops back to the camera
    /// via "Add Page" — drafts live here so a typed note survives the round-trip.
    var draftNote = ""
    var draftTripReference: CachedTripReference?

    func proceedToMetadata() {
        currentStep = .metadata
    }

    // MARK: - Save

    /// Reused across retries so a failed attempt never orphans files under an
    /// abandoned UUID (cleanup only walks receipt IDs that exist in SwiftData).
    private var pendingReceiptId: UUID?

    func saveReceipt(
        note: String?,
        tripReferenceId: UUID?,
        tripReferenceExternalId: String?,
        tripReferenceName: String?
    ) async -> LocalReceipt? {
        guard !pages.isEmpty else { return nil }
        isSaving = true
        error = nil
        defer { isSaving = false }

        let receiptId = pendingReceiptId ?? UUID()
        pendingReceiptId = receiptId

        let enhancement = pages.first?.enhancementMode ?? defaultEnhancementMode
        var receiptPages: [LocalReceiptPage] = []

        for index in pages.indices {
            // Any page failing to reach disk aborts the whole save — silently
            // dropping a page would be invisible data loss. The in-memory pages
            // are kept (released only after a durable save) so retry works.
            guard let processed = pages[index].processedImage else {
                ImageUtils.deleteReceiptImages(receiptId: receiptId)
                error = "Page \(index + 1) is no longer available. Please retake it."
                return nil
            }

            let resized = ImageUtils.resizeIfNeeded(processed)
            guard let jpegData = ImageUtils.compressToJPEG(resized),
                  let relativePath = ImageUtils.saveReceiptImage(
                    data: jpegData,
                    receiptId: receiptId,
                    pageIndex: index
                  ) else {
                ImageUtils.deleteReceiptImages(receiptId: receiptId)
                error = "Could not save page \(index + 1). Check available storage and try again."
                return nil
            }

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
            // Undo the inserts and this attempt's files; in-memory pages are
            // still intact, so the user's retry re-runs the full save.
            modelContext.rollback()
            ImageUtils.deleteReceiptImages(receiptId: receiptId)
            self.error = "Failed to save receipt: \(error.localizedDescription)"
            return nil
        }

        // Durable — now it's safe to release the full-resolution images.
        pendingReceiptId = nil
        for index in pages.indices {
            pages[index].originalImage = nil
            pages[index].processedImage = nil
        }

        return receipt
    }
}
