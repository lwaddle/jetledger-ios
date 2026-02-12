//
//  CachedAccount.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation
import SwiftData

@Model
class CachedAccount {
    @Attribute(.unique) var id: UUID
    var name: String
    var role: String
    var isDefault: Bool

    var accountRole: AccountRole? {
        AccountRole(rawValue: role)
    }

    init(id: UUID, name: String, role: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.role = role
        self.isDefault = isDefault
    }
}
