//
//  SyncService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import SwiftData

@Observable
class SyncService {
    var isSyncing = false
    var lastError: String?

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "SyncService")
    private let receiptAPI: ReceiptAPIService
    private let r2Upload: R2UploadService
    private let networkMonitor: NetworkMonitor
    private let modelContext: ModelContext
    private var isProcessingQueue = false

    init(
        receiptAPI: ReceiptAPIService,
        r2Upload: R2UploadService,
        networkMonitor: NetworkMonitor,
        modelContext: ModelContext
    ) {
        self.receiptAPI = receiptAPI
        self.r2Upload = r2Upload
        self.networkMonitor = networkMonitor
        self.modelContext = modelContext
    }

    // MARK: - Queue Processing

    func processQueue() {
        guard !isProcessingQueue, networkMonitor.isConnected else { return }
        isProcessingQueue = true
        isSyncing = true

        Task {
            defer {
                isProcessingQueue = false
                isSyncing = false
            }

            let queuedRaw = SyncStatus.queued.rawValue
            let descriptor = FetchDescriptor<LocalReceipt>(
                predicate: #Predicate<LocalReceipt> { receipt in
                    receipt.syncStatusRaw == queuedRaw
                },
                sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
            )

            guard let receipts = try? modelContext.fetch(descriptor), !receipts.isEmpty else {
                return
            }

            for receipt in receipts {
                guard networkMonitor.isConnected else { break }
                await uploadReceipt(receipt)
            }
        }
    }

    private func uploadReceipt(_ receipt: LocalReceipt) async {
        receipt.syncStatus = .uploading
        trySave()

        do {
            let sortedPages = receipt.pages.sorted { $0.sortOrder < $1.sortOrder }
            var imageRequests: [CreateReceiptImageRequest] = []

            // Upload each page to R2
            for page in sortedPages {
                let fullPath = ImageUtils.documentsDirectory()
                    .appendingPathComponent(page.localImagePath)
                guard let imageData = try? Data(contentsOf: fullPath) else {
                    throw SyncError.imageNotFound(page.localImagePath)
                }

                let fileName = (page.localImagePath as NSString).lastPathComponent

                // Get presigned URL
                let uploadInfo = try await receiptAPI.getUploadURL(
                    accountId: receipt.accountId,
                    stagedReceiptId: receipt.id,
                    fileName: fileName,
                    contentType: page.contentType.rawValue,
                    fileSize: imageData.count
                )

                // Upload to R2
                try await r2Upload.upload(
                    data: imageData,
                    to: uploadInfo.uploadUrl,
                    contentType: page.contentType.rawValue
                )

                page.r2ImagePath = uploadInfo.filePath

                imageRequests.append(CreateReceiptImageRequest(
                    filePath: uploadInfo.filePath,
                    fileName: fileName,
                    fileSize: imageData.count,
                    sortOrder: page.sortOrder,
                    contentType: page.contentType.rawValue
                ))
            }

            // Create staged receipt record
            let createRequest = CreateReceiptRequest(
                accountId: receipt.accountId,
                note: receipt.note,
                tripReferenceId: receipt.tripReferenceId,
                images: imageRequests
            )

            let response = try await receiptAPI.createReceipt(createRequest)

            receipt.serverReceiptId = response.id
            receipt.syncStatus = .uploaded
            receipt.serverStatus = .pending
            trySave()

        } catch let apiError as APIError where apiError == .unauthorized {
            // Auth error — revert to queued, user needs to re-authenticate
            receipt.syncStatus = .queued
            trySave()
        } catch {
            receipt.syncStatus = .failed
            lastError = error.localizedDescription
            trySave()
        }
    }

    // MARK: - Status Sync

    func syncReceiptStatuses() async {
        guard networkMonitor.isConnected else { return }

        let uploadedRaw = SyncStatus.uploaded.rawValue
        let pendingRaw = ServerStatus.pending.rawValue
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { receipt in
                receipt.syncStatusRaw == uploadedRaw &&
                receipt.serverStatusRaw == pendingRaw
            }
        )

        guard let receipts = try? modelContext.fetch(descriptor), !receipts.isEmpty else {
            return
        }

        // Process in batches
        let batchSize = AppConstants.Sync.statusCheckBatchSize
        for batchStart in stride(from: 0, to: receipts.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, receipts.count)
            let batch = Array(receipts[batchStart..<batchEnd])
            let serverIds = batch.compactMap(\.serverReceiptId)

            guard !serverIds.isEmpty else { continue }

            do {
                let statuses = try await receiptAPI.checkStatus(ids: serverIds)
                let statusMap = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })

                for receipt in batch {
                    guard let serverId = receipt.serverReceiptId,
                          let status = statusMap[serverId] else { continue }

                    switch status.status {
                    case "processed":
                        receipt.serverStatus = .processed
                        if receipt.terminalStatusAt == nil {
                            receipt.terminalStatusAt = Date()
                        }
                    case "rejected":
                        receipt.serverStatus = .rejected
                        receipt.rejectionReason = status.rejectionReason
                        if receipt.terminalStatusAt == nil {
                            receipt.terminalStatusAt = Date()
                        }
                    default:
                        break // still pending
                    }
                }

                trySave()
            } catch {
                // Status check is non-critical; skip this batch
            }
        }
    }

    // MARK: - Retry

    func retryReceipt(_ receipt: LocalReceipt) {
        receipt.syncStatus = .queued
        trySave()
        processQueue()
    }

    func retryAllFailed() {
        let failedRaw = SyncStatus.failed.rawValue
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { receipt in
                receipt.syncStatusRaw == failedRaw
            }
        )
        guard let failed = try? modelContext.fetch(descriptor) else { return }
        for receipt in failed {
            receipt.syncStatus = .queued
        }
        trySave()
        processQueue()
    }

    // MARK: - Delete

    func deleteReceipt(_ receipt: LocalReceipt) async throws {
        // Delete from server if uploaded
        if let serverId = receipt.serverReceiptId, receipt.syncStatus == .uploaded {
            try await receiptAPI.deleteReceipt(id: serverId)
        }

        // Delete local images
        ImageUtils.deleteReceiptImages(receiptId: receipt.id)

        // Delete from SwiftData
        modelContext.delete(receipt)
        trySave()
    }

    // MARK: - Metadata Update

    func updateReceiptMetadata(
        _ receipt: LocalReceipt,
        note: String?,
        tripReferenceId: UUID?,
        tripReferenceExternalId: String?,
        tripReferenceName: String?
    ) async throws {
        // Update server if uploaded
        if let serverId = receipt.serverReceiptId, receipt.syncStatus == .uploaded {
            try await receiptAPI.updateReceipt(
                id: serverId,
                note: note,
                tripReferenceId: tripReferenceId
            )
        }

        // Update local
        receipt.note = note
        receipt.tripReferenceId = tripReferenceId
        receipt.tripReferenceExternalId = tripReferenceExternalId
        receipt.tripReferenceName = tripReferenceName
        trySave()
    }

    // MARK: - Startup

    func resetStuckUploads() {
        let uploadingRaw = SyncStatus.uploading.rawValue
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { receipt in
                receipt.syncStatusRaw == uploadingRaw
            }
        )
        guard let stuck = try? modelContext.fetch(descriptor) else { return }
        for receipt in stuck {
            receipt.syncStatus = .queued
        }
        trySave()
    }

    // MARK: - Network Change

    func handleNetworkChange(isConnected: Bool) {
        if isConnected {
            processQueue()
        }
    }

    // MARK: - Cleanup

    func performCleanup() {
        let retentionDays = UserDefaults.standard.object(forKey: AppConstants.Cleanup.imageRetentionKey) as? Int
            ?? AppConstants.Cleanup.defaultImageRetentionDays
        let imageCutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
        let metadataCutoff = Calendar.current.date(
            byAdding: .day,
            value: -(retentionDays * AppConstants.Cleanup.metadataRetentionMultiplier),
            to: Date()
        )!

        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { receipt in
                receipt.terminalStatusAt != nil
            }
        )

        guard let receipts = try? modelContext.fetch(descriptor) else { return }

        for receipt in receipts {
            guard let terminalDate = receipt.terminalStatusAt else { continue }

            if terminalDate < metadataCutoff {
                // Phase 2: delete images (if not already) and the SwiftData record
                if !receipt.imagesCleanedUp {
                    ImageUtils.deleteReceiptImages(receiptId: receipt.id)
                }
                modelContext.delete(receipt)
            } else if terminalDate < imageCutoff && !receipt.imagesCleanedUp {
                // Phase 1: delete local images, keep metadata
                ImageUtils.deleteReceiptImages(receiptId: receipt.id)
                receipt.imagesCleanedUp = true
            }
        }

        trySave()
    }

    func migrateTerminalTimestamps() {
        let processedRaw = ServerStatus.processed.rawValue
        let rejectedRaw = ServerStatus.rejected.rawValue
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { receipt in
                receipt.terminalStatusAt == nil &&
                (receipt.serverStatusRaw == processedRaw || receipt.serverStatusRaw == rejectedRaw)
            }
        )

        guard let receipts = try? modelContext.fetch(descriptor), !receipts.isEmpty else { return }

        let now = Date()
        for receipt in receipts {
            receipt.terminalStatusAt = now
        }
        trySave()
    }

    // MARK: - Helpers

    private func trySave() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Sync Errors

private enum SyncError: Error {
    case imageNotFound(String)
}

// Conformance for pattern matching in catch
extension APIError: Equatable {
    static func == (lhs: APIError, rhs: APIError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized): true
        case (.forbidden, .forbidden): true
        case (.conflict, .conflict): true
        case (.fileTooLarge, .fileTooLarge): true
        case (.serverError(let a), .serverError(let b)): a == b
        default: false
        }
    }
}
