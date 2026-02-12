//
//  ReceiptDetailView.swift
//  JetLedger
//

import SwiftUI

struct ReceiptDetailView: View {
    let receipt: LocalReceipt

    @Environment(SyncService.self) private var syncService
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false
    @State private var errorMessage: String?
    @State private var showError = false

    private var isEditable: Bool {
        receipt.serverStatus != .processed && receipt.serverStatus != .rejected
    }

    var body: some View {
        VStack(spacing: 0) {
            // Image gallery
            ImageGalleryView(pages: receipt.pages)
                .frame(maxHeight: .infinity)

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
        .alert("Error", isPresented: $showError) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unexpected error occurred.")
        }
        .sheet(isPresented: $showEditSheet) {
            EditMetadataSheet(receipt: receipt)
        }
    }

    // MARK: - Actions Menu

    private var actionsMenu: some View {
        Menu {
            Button {
                showEditSheet = true
            } label: {
                Label("Edit Metadata", systemImage: "pencil")
            }

            if receipt.syncStatus == .failed || receipt.syncStatus == .queued {
                Button {
                    syncService.retryReceipt(receipt)
                } label: {
                    Label("Retry Upload", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
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
                if let tripId = receipt.tripReferenceExternalId {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane")
                            .foregroundStyle(.secondary)
                        Text(tripId)
                            .fontDesign(.monospaced)
                        if let name = receipt.tripReferenceName {
                            Text("— \(name)")
                                .foregroundStyle(.secondary)
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
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func deleteReceipt() {
        Task {
            do {
                try await syncService.deleteReceipt(receipt)
                dismiss()
            } catch let error as APIError where error == .conflict {
                errorMessage = error.errorDescription
                showError = true
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
