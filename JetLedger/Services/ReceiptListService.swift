//
//  ReceiptListService.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import SwiftData

/// Pages `GET /api/receipts` and fetches `GET /api/receipts/{id}`, handing every
/// response to `ReceiptMirror`. The mirror is what the list actually renders, so
/// a failed request degrades to stale-but-present rather than to an empty screen.
@Observable
class ReceiptListService {
    /// Outcome of a detail fetch. A 404 means different things depending on
    /// whether the row was only a mirror or the user's own capture.
    enum DetailFetchResult {
        case ok(LocalReceipt)
        /// The server dropped a receipt this device captured. The row survives —
        /// its local images are the only copy — and is marked removed.
        case removedFromServer(LocalReceipt)
        /// A mirrored row the server no longer has. Deleted from the mirror.
        case deleted
        case failed(String)
    }

    var isLoadingPage = false
    var hasMore = true
    var total = 0
    var loadError: String?

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "ReceiptListService")
    private let receiptAPI: ReceiptAPIService
    private let networkMonitor: NetworkMonitor
    private let mirror: ReceiptMirror
    private var offset = 0
    private var pagedAccountId: UUID?

    init(
        receiptAPI: ReceiptAPIService,
        networkMonitor: NetworkMonitor,
        modelContext: ModelContext
    ) {
        self.receiptAPI = receiptAPI
        self.networkMonitor = networkMonitor
        self.mirror = ReceiptMirror(modelContext: modelContext)
    }

    // MARK: - Paging

    /// Re-fetches the newest page. Rows already paged in below it stay in the
    /// mirror — only the paging cursor resets.
    ///
    /// Returns the local ids of rows pruned as deleted server-side, so the caller
    /// can drop a live detail selection before it touches a destroyed model.
    @discardableResult
    func refresh(accountId: UUID) async -> Set<UUID> {
        offset = 0
        hasMore = true
        pagedAccountId = accountId
        return await fetchPage(accountId: accountId, offset: 0)
    }

    @discardableResult
    func loadNextPage(accountId: UUID) async -> Set<UUID> {
        guard hasMore, !isLoadingPage else { return [] }
        guard pagedAccountId == accountId else { return await refresh(accountId: accountId) }
        return await fetchPage(accountId: accountId, offset: offset + AppConstants.ReceiptList.pageSize)
    }

    private func fetchPage(accountId: UUID, offset requestedOffset: Int) async -> Set<UUID> {
        guard networkMonitor.isConnected else { return [] }
        // Checked and set before the first suspension point, so a duplicate
        // trigger from a scrolling view body is swallowed rather than issuing
        // the same page again.
        guard !isLoadingPage else { return [] }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let response = try await receiptAPI.listReceipts(
                status: nil,
                limit: AppConstants.ReceiptList.pageSize,
                offset: requestedOffset,
                accountId: accountId
            )

            mirror.upsert(response.receipts, accountId: accountId)
            let pruned = mirror.prune(response.receipts, accountId: accountId)

            total = response.total
            offset = requestedOffset
            // Trust an empty page over `total`: offset paging drifts when
            // receipts are created mid-scroll, and an empty page is the only
            // unambiguous end-of-list signal.
            hasMore = !response.receipts.isEmpty
                && (requestedOffset + response.receipts.count) < response.total
            loadError = nil
            return pruned
        } catch let apiError as APIError where apiError == .unauthorized() {
            // APIClient has already invoked onUnauthorized; nothing to surface.
            Self.logger.warning("Receipt list auth error — stopping")
            return []
        } catch {
            loadError = error.localizedDescription
            Self.logger.warning("Receipt list fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Detail

    func fetchDetail(serverReceiptId: UUID, accountId: UUID) async -> DetailFetchResult {
        do {
            let detail = try await receiptAPI.getReceipt(id: serverReceiptId, accountId: accountId)
            guard let row = mirror.upsertDetail(detail, accountId: accountId) else {
                return .failed("This receipt could not be loaded.")
            }
            return .ok(row)
        } catch let apiError as APIError where apiError == .serverError(404) {
            return handleDetailNotFound(serverReceiptId: serverReceiptId, accountId: accountId)
        } catch {
            Self.logger.warning("Receipt detail fetch failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// 404 means "not yours or not there" — the endpoint deliberately does not
    /// distinguish. Either way the receipt is unreachable, but the response
    /// depends on whether anything would be lost by deleting the row.
    private func handleDetailNotFound(serverReceiptId: UUID, accountId: UUID) -> DetailFetchResult {
        guard let row = mirror.receipt(forServerId: serverReceiptId, accountId: accountId) else {
            return .deleted
        }
        if row.isRemote {
            mirror.prune(byLocalId: row.id)
            return .deleted
        }
        // Matches how syncReceiptStatuses treats a receipt that vanished during
        // web review. The local images stay — they are the only copy.
        row.serverStatus = .rejected
        row.rejectionReason = "Removed during review on the web."
        if row.terminalStatusAt == nil {
            row.terminalStatusAt = Date()
        }
        mirror.save()
        return .removedFromServer(row)
    }
}
