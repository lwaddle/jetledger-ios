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

    private var color: Color {
        if let serverStatus {
            return switch serverStatus {
            case .pending: .blue
            case .processed: .green
            case .rejected: .red
            }
        }
        return switch syncStatus {
        case .queued: .secondary
        case .uploading: .blue
        case .uploaded: .blue
        case .failed: .red
        }
    }
}
