//
//  LocalReceiptPage.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation
import SwiftData

@Model
class LocalReceiptPage {
    var id: UUID
    var sortOrder: Int
    var localImagePath: String
    var r2ImagePath: String?
    var receipt: LocalReceipt?

    init(
        id: UUID = UUID(),
        sortOrder: Int,
        localImagePath: String,
        r2ImagePath: String? = nil
    ) {
        self.id = id
        self.sortOrder = sortOrder
        self.localImagePath = localImagePath
    }
}
