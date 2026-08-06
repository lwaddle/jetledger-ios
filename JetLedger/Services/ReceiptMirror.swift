//
//  ReceiptMirror.swift
//  JetLedger
//

import Foundation
import OSLog
import SwiftData

/// Reconciles server receipt rows into SwiftData. No networking lives here —
/// callers hand it decoded DTOs — which is what makes the merge and prune rules
/// testable without a URL session.
struct ReceiptMirror {
    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "ReceiptMirror")

    let modelContext: ModelContext

    // MARK: - Lookup

    /// Rows for one tenant. `accountId` is safe in a `#Predicate`; matching on
    /// `serverReceiptId` is not (UUID comparison beyond the stored account id has
    /// bitten us before), so that half is filtered in memory.
    private func rows(accountId: UUID) -> [LocalReceipt] {
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { $0.accountId == accountId }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func receipt(forServerId serverId: UUID, accountId: UUID) -> LocalReceipt? {
        rows(accountId: accountId).first { $0.serverReceiptId == serverId }
    }

    // MARK: - Upsert

    /// Merges a page of server rows. Existing rows are matched on
    /// `serverReceiptId`, which is what collapses a receipt this device uploaded
    /// into a single row rather than showing it twice.
    func upsert(_ dtos: [ReceiptSummaryDTO], accountId: UUID) {
        guard !dtos.isEmpty else { return }

        var byServerId: [UUID: LocalReceipt] = [:]
        for row in rows(accountId: accountId) {
            if let serverId = row.serverReceiptId {
                byServerId[serverId] = row
            }
        }

        for dto in dtos {
            if let existing = byServerId[dto.id] {
                apply(dto, to: existing)
            } else {
                let created = ServerDateFormatter.date(from: dto.createdAt) ?? Date()
                let row = LocalReceipt(
                    accountId: accountId,
                    capturedAt: created,
                    syncStatus: .uploaded
                )
                row.serverReceiptId = dto.id
                // No capture origin on this device: gates Retry / Manage Pages /
                // Delete, and marks the row as prunable.
                row.isRemote = true
                modelContext.insert(row)
                byServerId[dto.id] = row
                apply(dto, to: row)
            }
        }

        trySave()
    }

    /// Applies only server-owned fields. `capturedAt`, `isRemote`, `dismissedAt`,
    /// `syncStatus` and everything about local pages are deliberately untouched —
    /// the server has no opinion about them and would destroy local state.
    private func apply(_ dto: ReceiptSummaryDTO, to row: LocalReceipt) {
        row.note = dto.note
        row.tripReferenceId = dto.tripReferenceId
        row.sourceRaw = dto.source
        row.ocrStatusRaw = dto.ocrStatus
        row.expenseId = dto.expenseId
        row.imageCount = dto.imageCount
        row.serverCreatedAt = ServerDateFormatter.date(from: dto.createdAt)
        row.serverUpdatedAt = ServerDateFormatter.date(from: dto.updatedAt)
        row.rejectionReason = dto.rejectionReason
        row.firstImagePath = dto.firstImagePath
        row.firstImageMimeType = dto.firstImageMimeType
        row.lastSyncedAt = Date()
        // dto.thumbnailUrl is deliberately NOT stored: it expires in 15 minutes,
        // and a persisted URL would outlive its own validity. It is held in
        // memory by ReceiptListService for the life of the fetched page.

        if let status = ServerStatus(rawValue: dto.status) {
            row.serverStatus = status
            // Stamped the same way syncReceiptStatuses does, so retention
            // reclaims mirrored rows on the same schedule as local ones.
            if status != .pending, row.terminalStatusAt == nil {
                row.terminalStatusAt = Date()
            }
        }
    }

    // MARK: - Detail

    /// A presigned image URL and when it was handed to us. The timestamp is the
    /// whole point: without it an entry has no way to read as expired, and the
    /// downloader will keep spending the same dead URL.
    struct PresignedImageGrant {
        let url: URL
        let fetchedAt: Date
    }

    /// Presigned URLs from the most recent detail response, keyed by server
    /// image id. In memory only — they expire in 15 minutes, so persisting one
    /// would store a URL that outlives its own validity.
    ///
    /// Replaced wholesale by each detail fetch rather than accumulated: only one
    /// receipt's detail is ever in play, and the consumer runs immediately after.
    /// Keeping every URL the app has ever seen would grow without bound for
    /// entries that are dead within the quarter hour anyway.
    ///
    /// Read through `presignedImageURL(forImageId:now:)`, never directly: being
    /// replaced only by the *next* detail fetch is not an expiry policy. A page
    /// whose detail is current (`needsDetailFetch` false) but whose bytes never
    /// arrived reuses whatever sits here, so a download that failed on flaky
    /// signal and is retried twenty minutes later re-ran an entry R2 now answers
    /// with 403 — unrecoverable until another receipt's detail was fetched or
    /// the app restarted.
    static var presignedImageGrants: [UUID: PresignedImageGrant] = [:]

    /// The presigned URL for a server image, or nil once the grant has aged past
    /// the window the server signed it for. Absent and expired are the same
    /// answer on purpose: both send the caller to `getDownloadURL` for a fresh
    /// grant. Same shape as `ReceiptListService.thumbnailURL(for:now:)`.
    static func presignedImageURL(forImageId imageId: UUID, now: Date = Date()) -> URL? {
        guard let grant = presignedImageGrants[imageId] else { return nil }
        guard now.timeIntervalSince(grant.fetchedAt) < AppConstants.ReceiptList.detailImageURLUsableFor
        else { return nil }
        return grant.url
    }

    /// Applies a detail response and reconciles its images onto the receipt's
    /// pages. Returns the row so the caller can hand it to the downloader.
    @discardableResult
    func upsertDetail(_ dto: ReceiptDetailDTO, accountId: UUID) -> LocalReceipt? {
        upsert([dto.summary], accountId: accountId)
        guard let row = receipt(forServerId: dto.summary.id, accountId: accountId) else {
            Self.logger.error("Detail upsert found no row for \(dto.summary.id)")
            return nil
        }

        var byImageId: [UUID: LocalReceiptPage] = [:]
        for page in row.pages {
            if let imageId = page.serverImageId {
                byImageId[imageId] = page
            }
        }
        // A local capture's pages have no server image id yet. Match them by
        // sort order so the first detail fetch annotates them instead of adding
        // a second, byte-less copy of every page.
        var bySortOrder: [Int: LocalReceiptPage] = [:]
        for page in row.pages where page.serverImageId == nil {
            bySortOrder[page.sortOrder] = page
        }

        Self.presignedImageGrants = [:]
        let grantedAt = Date()
        for image in dto.images {
            if let raw = image.url, let url = URL(string: raw) {
                Self.presignedImageGrants[image.id] =
                    PresignedImageGrant(url: url, fetchedAt: grantedAt)
            }
            if let page = byImageId[image.id] ?? bySortOrder[image.sortOrder] {
                page.serverImageId = image.id
                page.serverFilePath = image.filePath
                page.sortOrder = image.sortOrder
                if let contentType = PageContentType(rawValue: image.mimeType) {
                    page.contentType = contentType
                }
                bySortOrder[image.sortOrder] = nil
            } else {
                let contentType = PageContentType(rawValue: image.mimeType) ?? .jpeg
                let page = LocalReceiptPage(
                    sortOrder: image.sortOrder,
                    // Where the bytes will land once downloaded. The path is
                    // built now so the downloader has a stable destination.
                    localImagePath: "receipts/\(row.id.uuidString)/"
                        + String(format: "page-%03d.%@", image.sortOrder + 1, contentType.fileExtension),
                    contentType: contentType
                )
                page.serverImageId = image.id
                page.serverFilePath = image.filePath
                page.imageDownloaded = false
                modelContext.insert(page)
                // Setting the inverse is what puts this on `row.pages`.
                // Appending as well double-inserts it.
                page.receipt = row
            }
        }

        row.detailFetchedAt = Date()
        trySave()
        return row
    }

    // MARK: - Prune

    /// Deletes mirrored rows the server has dropped.
    ///
    /// The server sorts newest-first, so a page proves exactly what exists
    /// between its newest and oldest entries and nothing outside that window.
    /// A mirrored row dated inside the window but absent from the response was
    /// deleted on the web.
    ///
    /// Only `isRemote` rows are eligible. A receipt that received its
    /// `serverReceiptId` after this request went out is legitimately absent from
    /// the response, and deleting it would destroy the only copy of the user's
    /// images. Local captures are removed by the user or by `syncReceiptStatuses`,
    /// never here.
    ///
    /// Returns the deleted rows' **local** ids so the caller can clear a live
    /// detail selection before the next body evaluation touches a dead model.
    @discardableResult
    func prune(_ dtos: [ReceiptSummaryDTO], accountId: UUID) -> Set<UUID> {
        guard let newestString = dtos.first?.createdAt,
              let oldestString = dtos.last?.createdAt,
              let newest = ServerDateFormatter.date(from: newestString),
              let oldest = ServerDateFormatter.date(from: oldestString)
        else { return [] }

        let returned = Set(dtos.map(\.id))
        var deleted: Set<UUID> = []

        for row in rows(accountId: accountId) where row.isRemote {
            guard let serverId = row.serverReceiptId,
                  let created = row.serverCreatedAt,
                  created >= oldest, created <= newest,
                  !returned.contains(serverId)
            else { continue }

            ImageUtils.deleteReceiptImages(receiptId: row.id)
            deleted.insert(row.id)
            modelContext.delete(row)
        }

        if !deleted.isEmpty {
            Self.logger.info("Pruned \(deleted.count) receipts removed server-side")
            trySave()
        }
        return deleted
    }

    /// Deletes one mirrored row by its local id. Used when a detail 404 proves a
    /// single receipt is gone without a page to reason about.
    func prune(byLocalId localId: UUID) {
        let descriptor = FetchDescriptor<LocalReceipt>(
            predicate: #Predicate<LocalReceipt> { $0.id == localId }
        )
        guard let row = (try? modelContext.fetch(descriptor))?.first, row.isRemote else { return }
        ImageUtils.deleteReceiptImages(receiptId: row.id)
        modelContext.delete(row)
        trySave()
    }

    /// Persists changes callers made directly to mirrored rows.
    func save() {
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
