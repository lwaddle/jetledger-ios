//
//  CachedTripReference.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation
import SwiftData

@Model
class CachedTripReference {
    @Attribute(.unique) var id: UUID
    var accountId: UUID
    var externalId: String?
    var name: String?
    var createdAt: Date?

    @Transient var displayTitle: String {
        externalId ?? name ?? "Untitled"
    }

    init(id: UUID, accountId: UUID, externalId: String? = nil, name: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.accountId = accountId
        self.externalId = externalId
        self.name = name
        self.createdAt = createdAt
    }
}
