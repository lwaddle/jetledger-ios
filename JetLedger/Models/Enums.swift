//
//  Enums.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import Foundation

// MARK: - Authentication

enum AuthState: Equatable {
    case loading
    case unauthenticated
    case mfaRequired(factorId: String)
    case authenticated
}

// MARK: - Receipts

enum SyncStatus: String, Codable {
    case queued
    case uploading
    case uploaded
    case failed
}

enum EnhancementMode: String, Codable, CaseIterable {
    case original
    case auto
    case blackAndWhite
}

enum ServerStatus: String, Codable {
    case pending
    case processed
    case rejected
}
