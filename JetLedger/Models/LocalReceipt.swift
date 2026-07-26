//
//  LocalReceipt.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation
import SwiftData

@Model
class LocalReceipt {
    @Attribute(.unique) var id: UUID
    var accountId: UUID
    var note: String?
    var tripReferenceId: UUID?
    var tripReferenceExternalId: String?
    var tripReferenceName: String?
    var capturedAt: Date
    var enhancementMode: EnhancementMode

    // Stored as raw strings so #Predicate can filter on them directly.
    // Use the computed `syncStatus` / `serverStatus` properties for typed access.
    var syncStatusRaw: String
    var serverStatusRaw: String?

    var serverReceiptId: UUID?
    var rejectionReason: String?
    var terminalStatusAt: Date?
    var imagesCleanedUp: Bool = false
    var isRemote: Bool = false
    var lastSyncedAt: Date?
    var retryCount: Int = 0
    var nextRetryAfter: Date?
    /// When this receipt first failed to upload, cleared once it succeeds. A
    /// "Failed" badge looks identical on day one and day eleven; this is what
    /// lets the list escalate one that has genuinely stalled.
    var firstFailedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \LocalReceiptPage.receipt)
    var pages: [LocalReceiptPage]

    // MARK: - Computed enum accessors

    @Transient
    var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .queued }
        set { syncStatusRaw = newValue.rawValue }
    }

    @Transient
    var serverStatus: ServerStatus? {
        get { serverStatusRaw.flatMap(ServerStatus.init(rawValue:)) }
        set { serverStatusRaw = newValue?.rawValue }
    }

    /// Failing for long enough that it is no longer plausibly a passing network
    /// blip. The list escalates these instead of leaving a red badge that reads
    /// the same on day one and day eleven.
    @Transient
    var isStalled: Bool {
        guard syncStatus == .failed, let firstFailedAt else { return false }
        return Date().timeIntervalSince(firstFailedAt) >= AppConstants.Sync.stalledAfter
    }

    init(
        id: UUID = UUID(),
        accountId: UUID,
        note: String? = nil,
        tripReferenceId: UUID? = nil,
        tripReferenceExternalId: String? = nil,
        tripReferenceName: String? = nil,
        capturedAt: Date = Date(),
        enhancementMode: EnhancementMode = .auto,
        syncStatus: SyncStatus = .queued,
        pages: [LocalReceiptPage] = []
    ) {
        self.id = id
        self.accountId = accountId
        self.note = note
        self.tripReferenceId = tripReferenceId
        self.tripReferenceExternalId = tripReferenceExternalId
        self.tripReferenceName = tripReferenceName
        self.capturedAt = capturedAt
        self.enhancementMode = enhancementMode
        self.syncStatusRaw = syncStatus.rawValue
        self.serverStatusRaw = nil
        self.pages = pages
    }
}
