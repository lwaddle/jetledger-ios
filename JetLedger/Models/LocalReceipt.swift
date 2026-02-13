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
    var id: UUID
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
