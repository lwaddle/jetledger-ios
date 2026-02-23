//
//  SyncService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import Supabase
import SwiftData
import UIKit

@Observable
class SyncService {
    var isSyncing = false
    var lastError: String?

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "SyncService")
    private let receiptAPI: ReceiptAPIService
    private let r2Upload: R2UploadService
    private let networkMonitor: NetworkMonitor
    private let modelContext: ModelContext
    private let supabase: SupabaseClient
    private var isProcessingQueue = false

    init(
        receiptAPI: ReceiptAPIService,
        r2Upload: R2UploadService,
        networkMonitor: NetworkMonitor,
        modelContext: ModelContext,
        supabase: SupabaseClient
    ) {
        self.receiptAPI = receiptAPI
        self.r2Upload = r2Upload
        self.networkMonitor = networkMonitor
        self.modelContext = modelContext
        self.supabase = supabase
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

            let now = Date()
            for receipt in receipts {
                guard networkMonitor.isConnected else { break }
                // Skip receipts in backoff period
                if let nextRetry = receipt.nextRetryAfter, nextRetry > now { continue }
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
                // Skip pages already uploaded in a previous partial attempt
                if let existingPath = page.r2ImagePath {
                    let fileName = (page.localImagePath as NSString).lastPathComponent
                    imageRequests.append(CreateReceiptImageRequest(
                        filePath: existingPath,
                        fileName: fileName,
                        fileSize: 0,
                        sortOrder: page.sortOrder,
                        contentType: page.contentType.rawValue
                    ))
                    continue
                }

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
                trySave()

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
            receipt.retryCount = 0
            receipt.nextRetryAfter = nil
            trySave()

        } catch let apiError as APIError where apiError == .unauthorized {
            // Auth error — revert to queued, user needs to re-authenticate
            receipt.syncStatus = .queued
            trySave()
        } catch {
            receipt.syncStatus = .failed
            receipt.retryCount += 1
            let delay = min(pow(2.0, Double(receipt.retryCount)) * 30.0, 3600.0)
            receipt.nextRetryAfter = Date().addingTimeInterval(delay)
            lastError = error.localizedDescription
            Self.logger.warning("Upload failed for receipt \(receipt.id): \(error.localizedDescription)")
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
            } catch let apiError as APIError where apiError == .unauthorized {
                Self.logger.warning("Status sync auth error — stopping")
                lastError = apiError.localizedDescription
                return
            } catch {
                Self.logger.warning("Status sync failed for batch: \(error.localizedDescription)")
                continue
            }
        }
    }

    // MARK: - Retry

    func retryReceipt(_ receipt: LocalReceipt) {
        receipt.syncStatus = .queued
        receipt.retryCount = 0
        receipt.nextRetryAfter = nil
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
            receipt.retryCount = 0
            receipt.nextRetryAfter = nil
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

    // MARK: - Remote Receipt Sync

    func fetchRemoteReceipts(for accountId: UUID) async {
        guard networkMonitor.isConnected else { return }
        guard let userId = supabase.auth.currentSession?.user.id else { return }

        do {
            let remoteReceipts: [RemoteReceipt] = try await withTimeout(
                seconds: AppConstants.Sync.networkQueryTimeoutSeconds
            ) { [supabase] in
                try await supabase
                    .from("staged_receipts")
                    .select("""
                        id, account_id, note, trip_reference_id, status, \
                        rejection_reason, created_at, \
                        staged_receipt_images(id, file_path, file_name, file_size, sort_order, content_type), \
                        trip_references(id, external_id, name)
                        """)
                    .eq("account_id", value: accountId.uuidString)
                    .eq("uploaded_by", value: userId.uuidString)
                    .order("created_at", ascending: false)
                    .limit(AppConstants.Sync.remoteFetchLimit)
                    .execute()
                    .value
            }

            // Build lookup of existing local receipts by serverReceiptId
            let allLocal = (try? modelContext.fetch(FetchDescriptor<LocalReceipt>())) ?? []
            let localByServerId: [UUID: LocalReceipt] = allLocal.reduce(into: [:]) { map, receipt in
                if let serverId = receipt.serverReceiptId {
                    map[serverId] = receipt
                }
            }

            let remoteIds = Set(remoteReceipts.map(\.id))

            for remote in remoteReceipts {
                if let existing = localByServerId[remote.id] {
                    updateLocalFromRemote(existing, remote: remote)
                } else {
                    createLocalFromRemote(remote, accountId: accountId)
                }
            }

            // Remove remote-only local receipts that no longer exist on server
            for receipt in allLocal where receipt.isRemote {
                if let serverId = receipt.serverReceiptId, !remoteIds.contains(serverId) {
                    ImageUtils.deleteReceiptImages(receiptId: receipt.id)
                    modelContext.delete(receipt)
                }
            }

            trySave()
        } catch {
            Self.logger.warning("Remote receipt fetch failed: \(error.localizedDescription)")
        }
    }

    func downloadPageImage(_ page: LocalReceiptPage) async throws {
        guard let r2Path = page.r2ImagePath else {
            throw SyncError.imageNotFound("No R2 path for page")
        }

        let downloadInfo = try await receiptAPI.getDownloadURL(filePath: r2Path)

        guard let url = URL(string: downloadInfo.downloadUrl) else {
            throw SyncError.imageNotFound("Invalid download URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SyncError.imageNotFound("Download failed")
        }

        // Determine receipt ID from the page's receipt
        guard let receipt = page.receipt else {
            throw SyncError.imageNotFound("Page has no parent receipt")
        }

        // Save to disk based on content type
        switch page.contentType {
        case .pdf:
            guard ImageUtils.saveReceiptPDF(data: data, receiptId: receipt.id, pageIndex: page.sortOrder) != nil else {
                throw SyncError.imageNotFound("Failed to save PDF")
            }
            _ = ImageUtils.savePDFThumbnail(pdfData: data, receiptId: receipt.id, pageIndex: page.sortOrder)
        case .jpeg:
            guard let image = UIImage(data: data) else {
                throw SyncError.imageNotFound("Invalid image data")
            }
            guard let jpegData = ImageUtils.compressToJPEG(ImageUtils.resizeIfNeeded(image)) else {
                throw SyncError.imageNotFound("Failed to compress image")
            }
            guard ImageUtils.saveReceiptImage(data: jpegData, receiptId: receipt.id, pageIndex: page.sortOrder) != nil else {
                throw SyncError.imageNotFound("Failed to save image")
            }
            _ = ImageUtils.saveThumbnail(from: image, receiptId: receipt.id, pageIndex: page.sortOrder)
        }

        page.imageDownloaded = true
        trySave()
    }

    private func updateLocalFromRemote(_ local: LocalReceipt, remote: RemoteReceipt) {
        local.note = remote.note
        local.tripReferenceId = remote.tripReferenceId
        local.tripReferenceExternalId = remote.tripReferences?.externalId
        local.tripReferenceName = remote.tripReferences?.name

        let newStatus = ServerStatus(rawValue: remote.status)
        if local.serverStatus != newStatus {
            local.serverStatus = newStatus
            if (newStatus == .processed || newStatus == .rejected), local.terminalStatusAt == nil {
                local.terminalStatusAt = Date()
            }
        }
        local.rejectionReason = remote.rejectionReason
        local.lastSyncedAt = Date()
    }

    private func createLocalFromRemote(_ remote: RemoteReceipt, accountId: UUID) {
        let localId = UUID()
        let receipt = LocalReceipt(
            id: localId,
            accountId: accountId,
            note: remote.note,
            tripReferenceId: remote.tripReferenceId,
            tripReferenceExternalId: remote.tripReferences?.externalId,
            tripReferenceName: remote.tripReferences?.name,
            capturedAt: remote.capturedDate,
            syncStatus: .uploaded
        )
        receipt.serverReceiptId = remote.id
        receipt.serverStatus = ServerStatus(rawValue: remote.status)
        receipt.rejectionReason = remote.rejectionReason
        receipt.isRemote = true
        receipt.lastSyncedAt = Date()

        if receipt.serverStatus == .processed || receipt.serverStatus == .rejected {
            receipt.terminalStatusAt = Date()
        }

        let sortedImages = remote.stagedReceiptImages.sorted { $0.sortOrder < $1.sortOrder }
        for (index, img) in sortedImages.enumerated() {
            let contentType = PageContentType(rawValue: img.contentType ?? "image/jpeg") ?? .jpeg
            let fileName = String(format: "page-%03d.\(contentType.fileExtension)", index + 1)
            let localPath = "receipts/\(localId.uuidString)/\(fileName)"

            let page = LocalReceiptPage(
                sortOrder: img.sortOrder,
                localImagePath: localPath,
                r2ImagePath: img.filePath,
                contentType: contentType
            )
            page.imageDownloaded = false
            receipt.pages.append(page)
        }

        modelContext.insert(receipt)
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
        cleanOrphanedFiles()
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

    // MARK: - Orphaned File Cleanup

    private func cleanOrphanedFiles() {
        let lastRunKey = "lastOrphanCleanupDate"
        let weekInterval: TimeInterval = 7 * 24 * 60 * 60

        if let lastRun = UserDefaults.standard.object(forKey: lastRunKey) as? Date,
           Date().timeIntervalSince(lastRun) < weekInterval {
            return
        }

        let receiptsDir = ImageUtils.documentsDirectory().appendingPathComponent("receipts")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: receiptsDir,
            includingPropertiesForKeys: nil
        ) else { return }

        // Get all receipt IDs from SwiftData
        let descriptor = FetchDescriptor<LocalReceipt>()
        guard let allReceipts = try? modelContext.fetch(descriptor) else { return }
        let knownIds = Set(allReceipts.map(\.id.uuidString))

        var removedCount = 0
        for dir in contents where dir.hasDirectoryPath {
            let dirName = dir.lastPathComponent
            if UUID(uuidString: dirName) != nil, !knownIds.contains(dirName) {
                try? FileManager.default.removeItem(at: dir)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            Self.logger.info("Removed \(removedCount) orphaned receipt directories")
        }

        UserDefaults.standard.set(Date(), forKey: lastRunKey)
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

// MARK: - Remote Receipt DTOs

private struct RemoteReceipt: Decodable {
    let id: UUID
    let accountId: UUID
    let note: String?
    let tripReferenceId: UUID?
    let status: String
    let rejectionReason: String?
    let createdAt: String
    let stagedReceiptImages: [RemoteReceiptImage]
    let tripReferences: RemoteTripReference?

    enum CodingKeys: String, CodingKey {
        case id, note, status
        case accountId = "account_id"
        case tripReferenceId = "trip_reference_id"
        case rejectionReason = "rejection_reason"
        case createdAt = "created_at"
        case stagedReceiptImages = "staged_receipt_images"
        case tripReferences = "trip_references"
    }

    var capturedDate: Date {
        ISO8601DateFormatter().date(from: createdAt) ?? Date()
    }
}

private struct RemoteReceiptImage: Decodable {
    let id: UUID
    let filePath: String
    let fileName: String
    let fileSize: Int?
    let sortOrder: Int
    let contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case fileName = "file_name"
        case fileSize = "file_size"
        case sortOrder = "sort_order"
        case contentType = "content_type"
    }
}

private struct RemoteTripReference: Decodable {
    let id: UUID
    let externalId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case externalId = "external_id"
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
