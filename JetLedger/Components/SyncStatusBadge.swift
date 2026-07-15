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

    // Dynamic: the light-mode values are too dark to read on a dark background
    // (~3:1), so dark mode gets brighter variants that clear WCAG 4.5:1.
    private static let accessibleGreen = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.80, blue: 0.45, alpha: 1)
            : UIColor(red: 0.15, green: 0.55, blue: 0.25, alpha: 1)
    })
    private static let accessibleRed = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.45, blue: 0.40, alpha: 1)
            : UIColor(red: 0.75, green: 0.12, blue: 0.08, alpha: 1)
    })

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
