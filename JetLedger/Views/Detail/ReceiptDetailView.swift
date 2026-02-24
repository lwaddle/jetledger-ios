//
//  ReceiptDetailView.swift
//  JetLedger
//

import SwiftUI

struct ReceiptDetailView: View {
    let receipt: LocalReceipt
    @Binding var selectedReceipt: LocalReceipt?

    @Environment(SyncService.self) private var syncService

    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false
    @State private var showManagePages = false
    @State private var showActionsSheet = false

    private var isEditable: Bool {
        receipt.serverStatus != .processed && receipt.serverStatus != .rejected
    }

    var body: some View {
        VStack(spacing: 0) {
            // Image gallery
            if receipt.imagesCleanedUp {
                ContentUnavailableView {
                    Label("Images Removed", systemImage: "clock.badge.checkmark")
                } description: {
                    if let date = receipt.terminalStatusAt {
                        Text("This receipt was \(receipt.serverStatus == .rejected ? "rejected" : "processed") on \(date, format: .dateTime.month().day().year()). Local images have been removed to save space.")
                    } else {
                        Text("Local images have been removed to save space.")
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ImageGalleryView(pages: receipt.pages)
                    .frame(maxHeight: .infinity)
            }

            Divider()

            // Metadata section
            metadataSection
        }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    actionsMenu
                }
            }
        }
        .alert("Delete Receipt", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteReceipt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete this receipt? This cannot be undone.")
        }
        .sheet(isPresented: $showEditSheet) {
            EditMetadataSheet(receipt: receipt)
        }
        .sheet(isPresented: $showManagePages) {
            ManagePagesSheet(receipt: receipt)
        }
    }

    // MARK: - Actions Menu

    private var actionsMenu: some View {
        Button {
            showActionsSheet = true
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .confirmationDialog("Actions", isPresented: $showActionsSheet, titleVisibility: .hidden) {
            Button("Edit Details") { showEditSheet = true }

            if !receipt.isRemote && receipt.pages.count > 1 && (receipt.syncStatus == .queued || receipt.syncStatus == .failed) {
                Button("Manage Pages") { showManagePages = true }
            }

            if !receipt.isRemote && (receipt.syncStatus == .failed || receipt.syncStatus == .queued) {
                Button("Retry Upload") { syncService.retryReceipt(receipt) }
            }

            Button("Delete", role: .destructive) { showDeleteConfirm = true }
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Rejected callout
                if receipt.serverStatus == .rejected {
                    rejectionCallout
                }

                // Note
                HStack {
                    Label(receipt.note ?? "No note", systemImage: "note.text")
                        .foregroundStyle(receipt.note != nil ? .primary : .secondary)
                }
                .font(.body)

                // Trip reference
                if receipt.tripReferenceExternalId != nil || receipt.tripReferenceName != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane")
                            .foregroundStyle(.secondary)
                        if let tripId = receipt.tripReferenceExternalId {
                            Text(tripId)
                                .fontDesign(.monospaced)
                            if let name = receipt.tripReferenceName {
                                Text("— \(name)")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let name = receipt.tripReferenceName {
                            Text(name)
                        }
                    }
                    .font(.subheadline)
                }

                // Date
                Label {
                    Text(receipt.capturedAt, format: .dateTime.month().day().year().hour().minute())
                } icon: {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                // Status + pages
                HStack {
                    SyncStatusBadge(
                        syncStatus: receipt.syncStatus,
                        serverStatus: receipt.serverStatus
                    )

                    Spacer()

                    if receipt.pages.contains(where: { $0.contentType == .pdf }) {
                        Label("PDF", systemImage: "doc.richtext")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.indigo.opacity(0.2), in: Capsule())
                    }

                    if receipt.pages.count > 1 {
                        Label("\(receipt.pages.count) pages", systemImage: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(maxHeight: 200)
    }

    private var rejectionCallout: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rejected")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let reason = receipt.rejectionReason {
                    Text(rejectionReasonLabel(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rejectionReasonLabel(_ reason: String) -> String {
        switch reason {
        case "duplicate": "Duplicate"
        case "unreadable": "Unreadable"
        case "not_business": "Not business related"
        case "other": "Other"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: - Actions

    private func deleteReceipt() {
        let receiptToDelete = receipt
        selectedReceipt = nil
        Task {
            do {
                try await syncService.deleteReceipt(receiptToDelete)
            } catch {
                // Surface via MainView's sync error alert
                syncService.lastError = error.localizedDescription
            }
        }
    }
}
