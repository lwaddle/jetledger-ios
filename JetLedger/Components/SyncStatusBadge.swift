//
//  SyncStatusBadge.swift
//  JetLedger
//
//  Created by Loren Waddle on 2/11/26.
//

import SwiftUI

struct SyncStatusBadge: View {
    let syncStatus: SyncStatus
    let serverStatus: ServerStatus?

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var icon: String {
        if let serverStatus {
            return switch serverStatus {
            case .pending: "cloud.fill"
            case .processed: "checkmark.circle.fill"
            case .rejected: "xmark.circle.fill"
            }
        }
        return switch syncStatus {
        case .queued: "clock.fill"
        case .uploading: "icloud.and.arrow.up.fill"
        case .uploaded: "cloud.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var label: String {
        if let serverStatus {
            return switch serverStatus {
            case .pending: "Uploaded"
            case .processed: "Processed"
            case .rejected: "Rejected"
            }
        }
        return switch syncStatus {
        case .queued: "Waiting to upload"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded"
        case .failed: "Failed"
        }
    }

    private static let accessibleGreen = Color(red: 0.15, green: 0.55, blue: 0.25)
    private static let accessibleRed = Color(red: 0.75, green: 0.12, blue: 0.08)

    private var color: Color {
        if let serverStatus {
            return switch serverStatus {
            case .pending: .blue
            case .processed: Self.accessibleGreen
            case .rejected: Self.accessibleRed
            }
        }
        return switch syncStatus {
        case .queued: .secondary
        case .uploading: .blue
        case .uploaded: .blue
        case .failed: Self.accessibleRed
        }
    }
}
