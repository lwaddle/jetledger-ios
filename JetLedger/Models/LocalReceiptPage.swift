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
    @Attribute(.unique) var id: UUID
    var sortOrder: Int
    var localImagePath: String
    var r2ImagePath: String?
    /// When the server issued the grant behind `r2ImagePath`. Unclaimed objects
    /// are reaped 24h after the grant, so a path older than that names nothing
    /// and must be re-uploaded rather than claimed. Nil on rows written before
    /// this was tracked — treated as expired, which is the safe reading.
    var r2GrantedAt: Date?
    /// The server's image row id, used to match server images to local pages
    /// across refetches.
    var serverImageId: UUID?
    /// The confirmed R2 object path, for `POST /api/receipts/download-url`.
    ///
    /// Deliberately not `r2ImagePath`: that is a 24h grant that the server reaps
    /// if unclaimed, which is why `r2GrantedAt` and `isGrantUsable` exist. This
    /// one names an object that already exists and does not expire. Folding them
    /// into one field is how the grant-expiry bug fixed in 044d085 comes back.
    var serverFilePath: String?
    /// When bytes fetched from the server landed on disk. Drives the reclaim
    /// clock for downloaded images, which have no terminal-status date to key on.
    var imageDownloadedAt: Date?
    var contentTypeRaw: String = "image/jpeg"
    /// Literally "bytes exist on disk at `localImagePath`". True from creation
    /// for captures; false for mirrored pages until fetched; set back to false by
    /// retention cleanup, which is what makes a cleaned-up receipt re-downloadable
    /// instead of a permanent dead end.
    var imageDownloaded: Bool = true
    var receipt: LocalReceipt?

    @Transient
    var contentType: PageContentType {
        get { PageContentType(rawValue: contentTypeRaw) ?? .jpeg }
        set { contentTypeRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        sortOrder: Int,
        localImagePath: String,
        r2ImagePath: String? = nil,
        contentType: PageContentType = .jpeg
    ) {
        self.id = id
        self.sortOrder = sortOrder
        self.localImagePath = localImagePath
        self.r2ImagePath = r2ImagePath
        self.contentTypeRaw = contentType.rawValue
    }
}
