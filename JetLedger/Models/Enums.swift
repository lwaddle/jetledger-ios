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

// MARK: - Accounts

enum AccountRole: String, Codable, Sendable {
    case admin
    case editor
    case viewer

    var canUpload: Bool {
        self != .viewer
    }
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

    var displayName: String {
        switch self {
        case .original: "Original"
        case .auto: "Auto"
        case .blackAndWhite: "Black & White"
        }
    }
}

enum ServerStatus: String, Codable {
    case pending
    case processed
    case rejected
}

// MARK: - Capture Flow

enum CaptureStep {
    case camera
    case preview
    case cropAdjust
    case multiPagePrompt
    case metadata
}
