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

    // Meridian semantic status colors (web docs/design.md § Theming); each
    // colorset carries a per-mode variant that clears WCAG 4.5:1 on its surface.
    private var color: Color {
        if let serverStatus {
            return switch serverStatus {
            case .pending: Color(.statusInfo)
            case .processed: Color(.statusSuccess)
            case .rejected: Color(.statusError)
            }
        }
        return switch syncStatus {
        case .queued: .secondary
        case .uploading: Color(.statusInfo)
        case .uploaded: Color(.statusInfo)
        case .failed: Color(.statusError)
        }
    }
}
