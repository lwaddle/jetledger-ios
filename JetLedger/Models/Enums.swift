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
    case mfaEnrollmentRequired
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

enum ExposureLevel: Int, CaseIterable {
    case minusTwo = -2
    case minusOne = -1
    case zero = 0
    case plusOne = 1
    case plusTwo = 2

    var evValue: Float {
        Float(rawValue) * 1.0
    }

    var displayLabel: String {
        switch self {
        case .minusTwo: "-2"
        case .minusOne: "-1"
        case .zero: "0"
        case .plusOne: "+1"
        case .plusTwo: "+2"
        }
    }
}

enum ServerStatus: String, Codable {
    case pending
    case processed
    case rejected
}

// MARK: - Page Content Type

enum PageContentType: String, Codable {
    case jpeg = "image/jpeg"
    case pdf = "application/pdf"

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .pdf: "pdf"
        }
    }
}

// MARK: - Flash Mode

enum FlashMode: String, CaseIterable {
    case auto
    case on
    case off

    var next: FlashMode {
        switch self {
        case .auto: .on
        case .on: .off
        case .off: .auto
        }
    }

    var iconName: String {
        switch self {
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .auto: "Flash auto"
        case .on: "Flash on"
        case .off: "Flash off"
        }
    }
}

// MARK: - Capture Flow

enum CaptureStep {
    case camera
    case preview
    case cropAdjust
    case multiPagePrompt
    case metadata
}

// MARK: - Import Flow

enum ImportStep {
    case preview
    case metadata
}

// MARK: - Camera Session

enum CameraSessionState {
    case idle
    case configuring
    case ready
    case running
    case failed(String)
}
