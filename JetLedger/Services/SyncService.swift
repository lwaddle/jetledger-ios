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
    private var queueTask: Task<Void, Never>?
    /// A trigger that arrives while a queue pass is running requeues one more
    /// pass instead of being dropped (a receipt captured mid-pass would otherwise
    /// wait for the next external trigger).
    private var queueRunRequested = false
    /// Receipts the user deleted while an upload was possibly in flight. The
    /// upload loop checks this after every suspension point so it never mutates
    /// a deleted model or creates a server record for a deleted receipt.
    private var cancelledReceiptIds: Set<UUID> = []

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

    /// Awaits any in-flight queue pass, including coalesced re-runs. Test seam:
    /// processQueue is fire-and-forget, so tests need a way to await completion.
    func waitForQueueDrain() async {
        while let task = queueTask {
            await task.value
        }
    }

    /// Cancels in-flight queue work. Must be called before the service is
    /// discarded (sign-out, account wipe) — otherwise the retained task keeps
    /// uploading against a cleared session and mutates models that
    /// `clearAllData()` is about to delete.
    func shutdown() {
        queueTask?.cancel()
        queueTask = nil
        queueRunRequested = false
        isSyncing = false
    }

    // MARK: - Queue Processing

    func processQueue() {
        guard networkMonitor.isConnected else { return }
        guard queueTask == nil else {
            queueRunRequested = true
            return
        }
        isSyncing = true

        queueTask = Task {
            defer {
                isSyncing = false
                queueTask = nil
                if queueRunRequested {
                    queueRunRequested = false
                    processQueue()
                }
            }

            let queuedRaw = SyncStatus.queued.rawValue
            let failedRaw = SyncStatus.failed.rawValue
            let descriptor = FetchDescriptor<LocalReceipt>(
                predicate: #Predicate<LocalReceipt> { receipt in
                    receipt.syncStatusRaw == queuedRaw || receipt.syncStatusRaw == failedRaw
                },
                sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
            )

            guard let receipts = try? modelContext.fetch(descriptor), !receipts.isEmpty else {
                return
            }

            let now = Date()
            for receipt in receipts {
                guard networkMonitor.isConnected, !Task.isCancelled else { break }
                // Failed receipts auto-retry once their backoff has elapsed;
                // permanent failures park at .distantFuture until manual retry.
                if receipt.syncStatus == .failed,
                   let nextRetry = receipt.nextRetryAfter, nextRetry > now { continue }
                if cancelledReceiptIds.contains(receipt.id) { continue }
                let outcome = await uploadReceipt(receipt)
                if outcome == .authFailure { break }
            }
        }
    }

    private enum UploadOutcome {
        case success
        case authFailure
        case failure
        case cancelled
    }

    /// An upload URL is a 24h lease, not a reservation. A grant older than the
    /// usable window — or one with no recorded age, which only happens on rows
    /// written before grants were timestamped — must be re-uploaded rather than
    /// claimed. Re-uploading costs one request; claiming a reaped path strands
    /// the receipt permanently.
    private static func isGrantUsable(_ page: LocalReceiptPage) -> Bool {
        guard let grantedAt = page.r2GrantedAt else { return false }
        return Date().timeIntervalSince(grantedAt) < AppConstants.Sync.uploadGrantUsableFor
    }

    /// Drops every stored grant on a receipt so the next attempt re-uploads
    /// from the local images, which are still on disk.
    private func clearUploadGrants(on receipt: LocalReceipt) {
        for page in receipt.pages {
            page.r2ImagePath = nil
            page.r2GrantedAt = nil
        }
    }

    /// True when the upload loop must stop touching this receipt: the task was
    /// cancelled (sign-out tore the service down) or the user deleted the
    /// receipt while the upload was suspended.
    private func isFenced(_ receipt: LocalReceipt) -> Bool {
        Task.isCancelled || cancelledReceiptIds.contains(receipt.id)
    }

    private func uploadReceipt(_ receipt: LocalReceipt) async -> UploadOutcome {
        receipt.syncStatus = .uploading
        trySave()

        do {
            let sortedPages = receipt.pages.sorted { $0.sortOrder < $1.sortOrder }
            var imageRequests: [CreateReceiptImageRequest] = []

            // Upload each page to R2
            for page in sortedPages {
                let fullPath = ImageUtils.documentsDirectory()
                    .appendingPathComponent(page.localImagePath)
                let fileName = (page.localImagePath as NSString).lastPathComponent

                // Skip pages already uploaded in a previous partial attempt —
                // but report their real size, not 0, in the create request.
                // A grant the server has since reaped is worse than no grant:
                // claiming it 400s forever while the local file sits unused.
                if let existingPath = page.r2ImagePath, Self.isGrantUsable(page) {
                    let size = (try? FileManager.default
                        .attributesOfItem(atPath: fullPath.path)[.size] as? Int) ?? 0
                    imageRequests.append(CreateReceiptImageRequest(
                        filePath: existingPath,
                        fileName: fileName,
                        fileSize: size,
                        sortOrder: page.sortOrder,
                        contentType: page.contentType.rawValue
                    ))
                    continue
                }

                guard let imageData = try? Data(contentsOf: fullPath) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [
                        NSLocalizedDescriptionKey: "Image not found: \(page.localImagePath)"
                    ])
                }

                // Get presigned URL
                let uploadInfo = try await receiptAPI.getUploadURL(
                    accountId: receipt.accountId,
                    stagedReceiptId: receipt.id,
                    fileName: fileName,
                    contentType: page.contentType.rawValue,
                    fileSize: imageData.count
                )
                if isFenced(receipt) { return .cancelled }

                // Upload to R2
                try await r2Upload.upload(
                    data: imageData,
                    to: uploadInfo.uploadUrl,
                    contentType: page.contentType.rawValue
                )
                if isFenced(receipt) { return .cancelled }

                page.r2ImagePath = uploadInfo.filePath
                page.r2GrantedAt = Date()
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
                tripReferenceId: receipt.tripReferenceId?.uuidString.lowercased(),
                images: imageRequests
            )

            let response = try await receiptAPI.createReceipt(
                createRequest,
                accountId: receipt.accountId
            )
            if isFenced(receipt) {
                // The user deleted this receipt while the create was in flight —
                // the server record now exists for a receipt the user believes is
                // gone. Best-effort delete; the model must not be touched.
                try? await receiptAPI.deleteReceipt(id: response.id, accountId: receipt.accountId)
                return .cancelled
            }

            receipt.serverReceiptId = response.id
            receipt.syncStatus = .uploaded
            receipt.serverStatus = .pending
            receipt.retryCount = 0
            receipt.nextRetryAfter = nil
            receipt.firstFailedAt = nil
            // MainView alerts on lastError *changing* — a stale value left here
            // silently swallows the alert for an identical later failure.
            lastError = nil
            trySave()
            return .success

        } catch is CancellationError {
            return .cancelled
        } catch let apiError as APIError where apiError == .unauthorized() {
            if isFenced(receipt) { return .cancelled }
            // Auth error — revert to queued, user needs to re-authenticate
            receipt.syncStatus = .queued
            trySave()
            return .authFailure
        } catch {
            if isFenced(receipt) { return .cancelled }
            receipt.syncStatus = .failed
            receipt.retryCount += 1
            // Stamped once, on the first failure — later attempts must not push
            // it forward or a receipt failing every hour never looks stalled.
            if receipt.firstFailedAt == nil {
                receipt.firstFailedAt = Date()
            }
            let apiError = error as? APIError

            // Both of these mean the stored file_path names nothing: the
            // reaper took it, or the server deleted it for being oversized.
            // Leaving the path behind makes every future attempt — including a
            // manual retry — re-send a claim that can only 400.
            if apiError == .uploadedImageMissing || apiError == .fileTooLarge {
                clearUploadGrants(on: receipt)
            }

            if apiError == .fileTooLarge || apiError == .forbidden {
                // Permanent — retrying can never succeed; park until the user
                // intervenes (manual retry clears this).
                receipt.nextRetryAfter = .distantFuture
            } else {
                let delay = min(pow(2.0, Double(receipt.retryCount)) * 30.0, 3600.0)
                receipt.nextRetryAfter = Date().addingTimeInterval(delay)
            }
            lastError = error.localizedDescription
            Self.logger.warning("Upload failed for receipt \(receipt.id): \(error.localizedDescription)")
            trySave()
            return .failure
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

        // The status endpoint is tenant-scoped via X-Account-ID, so receipts
        // must be polled per account — asking with the wrong header silently
        // returns no match and the status never flips.
        let byAccount = Dictionary(grouping: receipts, by: \.accountId)
        let batchSize = AppConstants.Sync.statusCheckBatchSize

        for (accountId, accountReceipts) in byAccount {
            for batchStart in stride(from: 0, to: accountReceipts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, accountReceipts.count)
                let batch = Array(accountReceipts[batchStart..<batchEnd])
                let serverIds = batch.compactMap(\.serverReceiptId)

                guard !serverIds.isEmpty else { continue }

                do {
                    let statuses = try await receiptAPI.checkStatus(ids: serverIds, accountId: accountId)
                    let statusMap = Dictionary(
                        statuses.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )

                    for receipt in batch {
                        guard let serverId = receipt.serverReceiptId else { continue }
                        guard let status = statusMap[serverId] else {
                            // Present in the request but absent from a successful
                            // response: the staged receipt was removed during
                            // review on the web. Without this it stays "pending"
                            // locally forever and its images are never reclaimed.
                            receipt.serverStatus = .rejected
                            receipt.rejectionReason = "Removed during review on the web."
                            if receipt.terminalStatusAt == nil {
                                receipt.terminalStatusAt = Date()
                            }
                            continue
                        }

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
                } catch let apiError as APIError where apiError == .unauthorized() {
                    Self.logger.warning("Status sync auth error — stopping")
                    lastError = apiError.localizedDescription
                    return
                } catch {
                    Self.logger.warning("Status sync failed for batch: \(error.localizedDescription)")
                    continue
                }
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
        // Fence first: if an upload of this receipt is suspended mid-flight,
        // the loop must not resurrect the model or create a server record.
        cancelledReceiptIds.insert(receipt.id)

        // Delete from server if it ever made it there. A 404 means it's already
        // gone (deleted on the web) — that must not block local deletion.
        if let serverId = receipt.serverReceiptId {
            do {
                try await receiptAPI.deleteReceipt(id: serverId, accountId: receipt.accountId)
            } catch let apiError as APIError where apiError == .serverError(404) {
                Self.logger.info("Receipt \(serverId) already deleted server-side")
            }
        }

        // Delete local images
        ImageUtils.deleteReceiptImages(receiptId: receipt.id)

        // Delete from SwiftData
        modelContext.delete(receipt)
        trySave()
    }

    /// Removes a rejected receipt from this device only. The server record is
    /// deliberately left alone — permanently deleting a rejected receipt is an
    /// admin decision made on the web.
    func removeRejectedReceiptLocally(_ receipt: LocalReceipt) {
        guard receipt.serverStatus == .rejected else { return }
        ImageUtils.deleteReceiptImages(receiptId: receipt.id)
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
                tripReferenceId: tripReferenceId,
                accountId: receipt.accountId
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

    /// Reclaims disk. Deliberately does **not** delete SwiftData records: the
    /// list is a mirror of rows the server owns, so deleting one only forces a
    /// refetch — and destroys the local-only `dismissedAt` on the way, which is
    /// how a receipt the user swiped away comes back a day later. Rows leave the
    /// mirror through `ReceiptMirror.prune`, which acts on server evidence.
    ///
    /// Returns the IDs of receipts whose records were deleted so callers can drop
    /// live references. Nothing deletes records here today; the contract is kept
    /// because the iPad detail selection depends on it and pruning uses the same
    /// shape.
    @discardableResult
    func performCleanup() -> Set<UUID> {
        let retentionDays = UserDefaults.standard.object(forKey: AppConstants.Cleanup.imageRetentionKey) as? Int
            ?? AppConstants.Cleanup.defaultImageRetentionDays
        let imageCutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!

        reclaimTerminalReceiptImages(olderThan: imageCutoff)
        reclaimDownloadedImages(olderThan: imageCutoff)

        trySave()
        cleanOrphanedFiles()
        return []
    }

    /// Terminal receipts give up their local images once the retention window
    /// passes. `imageDownloaded = false` is what makes this recoverable: the
    /// detail view re-downloads from the server instead of showing a permanent
    /// "Images Removed".
    private func reclaimTerminalReceiptImages(olderThan cutoff: Date) {
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { receipt in
                receipt.terminalStatusAt != nil
            }
        )
        guard let receipts = try? modelContext.fetch(descriptor) else { return }

        for receipt in receipts {
            guard let terminalDate = receipt.terminalStatusAt,
                  terminalDate < cutoff,
                  !receipt.imagesCleanedUp
            else { continue }

            ImageUtils.deleteReceiptImages(receiptId: receipt.id)
            receipt.imagesCleanedUp = true
            for page in receipt.pages {
                page.imageDownloaded = false
                page.imageDownloadedAt = nil
            }
        }
    }

    /// Images fetched from the server are a cache, and a receipt that never
    /// reaches a terminal status — a pending email forward, say — would otherwise
    /// hold its downloaded bytes forever.
    ///
    /// Keyed on `imageDownloadedAt`, not on the receipt's `isRemote` flag: a local
    /// capture whose files were reclaimed above and later re-downloaded for
    /// viewing is `isRemote == false`, but those bytes came from the server and
    /// must be reclaimable again. Original captures never carry the stamp.
    private func reclaimDownloadedImages(olderThan cutoff: Date) {
        let descriptor = FetchDescriptor<LocalReceiptPage>()
        guard let pages = try? modelContext.fetch(descriptor) else { return }

        for page in pages {
            guard let downloadedAt = page.imageDownloadedAt,
                  downloadedAt < cutoff,
                  page.imageDownloaded
            else { continue }

            ImageUtils.deletePageImage(relativePath: page.localImagePath)
            page.imageDownloaded = false
            page.imageDownloadedAt = nil
        }
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
