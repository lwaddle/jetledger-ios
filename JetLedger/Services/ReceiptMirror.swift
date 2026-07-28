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
        row.lastSyncedAt = Date()

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

        for image in dto.images {
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

    // MARK: - Helpers

    private func trySave() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}
