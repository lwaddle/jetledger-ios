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
    var syncStatus: SyncStatus
    var serverReceiptId: UUID?
    var serverStatus: ServerStatus?
    var rejectionReason: String?

    @Relationship(deleteRule: .cascade, inverse: \LocalReceiptPage.receipt)
    var pages: [LocalReceiptPage]

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
        self.syncStatus = syncStatus
        self.pages = pages
    }
}
