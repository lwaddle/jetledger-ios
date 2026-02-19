//
//  PendingImport.swift
//  JetLedger
//

import Foundation

struct PendingImport: Codable, Identifiable {
    let id: UUID
    let files: [PendingImportFile]
    let createdAt: Date

    init(id: UUID = UUID(), files: [PendingImportFile], createdAt: Date = Date()) {
        self.id = id
        self.files = files
        self.createdAt = createdAt
    }
}

struct PendingImportFile: Codable {
    let relativePath: String
    let originalFileName: String
    let contentType: String  // MIME type: "image/jpeg" or "application/pdf"
    let fileSize: Int
}
