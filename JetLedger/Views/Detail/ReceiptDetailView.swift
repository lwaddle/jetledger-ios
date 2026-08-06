//
//  ReceiptDetailView.swift
//  JetLedger
//

import SwiftUI

struct ReceiptDetailView: View {
    let receipt: LocalReceipt
    @Binding var selectedReceipt: LocalReceipt?

    @Environment(SyncService.self) private var syncService
    @Environment(ReceiptListService.self) private var receiptListService
    @Environment(ReceiptImageDownloader.self) private var imageDownloader
    @Environment(NetworkMonitor.self) private var networkMonitor

    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false
    @State private var showManagePages = false
    @State private var showActionsSheet = false
    @State private var isLoadingImages = false
    @State private var imageLoadError: String?
    @State private var removedFromServer = false

    private var isEditable: Bool {
        receipt.serverStatus != .processed && receipt.serverStatus != .rejected
    }

    /// "PDF · N pages" for a single-record multi-page PDF; plain "PDF" when the
    /// receipt mixes records (the separate "N pages" label covers the count)
    /// or the file is gone.
    private var pdfLabel: String? {
        guard let pdfPage = receipt.pages.first(where: { $0.contentType == .pdf }) else { return nil }
        if receipt.pages.count == 1,
           let pageCount = ImageUtils.pdfPageCount(relativePath: pdfPage.localImagePath),
           pageCount > 1 {
            return "PDF · \(pageCount) pages"
        }
        return "PDF"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Image gallery
            if isLoadingImages && receipt.pages.allSatisfy({ !$0.imageDownloaded }) {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading receipt…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let imageLoadError {
                ContentUnavailableView {
                    Label("Couldn't Load Images", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(imageLoadError)
                } actions: {
                    Button("Try Again") {
                        Task { await loadRemoteContentIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(.brandPrimary))
                }
                .frame(maxHeight: .infinity)
            } else if receipt.pages.isEmpty || receipt.pages.allSatisfy({ !$0.imageDownloaded }) {
                emptyImageState
            } else {
                ImageGalleryView(pages: receipt.pages.filter(\.imageDownloaded))
                    .frame(maxHeight: .infinity)
            }

            Divider()

            // Metadata section
            metadataSection
        }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: receipt.id) {
            await loadRemoteContentIfNeeded()
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            // A receipt opened offline fills itself in when signal returns,
            // rather than making the user back out and re-enter.
            guard isConnected, receipt.pages.contains(where: { !$0.imageDownloaded })
            else { return }
            Task { await loadRemoteContentIfNeeded() }
        }
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

    // MARK: - Empty Image State

    /// Nothing on disk. What that means depends on connectivity, not on
    /// retention: a receipt whose bytes are one request away must never be
    /// described as having had its images removed.
    @ViewBuilder
    private var emptyImageState: some View {
        switch ReceiptDetailContent.emptyState(
            for: receipt, isConnected: networkMonitor.isConnected
        ) {
        case .retryable:
            ContentUnavailableView {
                Label("Couldn't Load Image", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("The receipt image didn't download. Try again.")
            } actions: {
                Button("Try Again") {
                    Task { await loadRemoteContentIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(.brandPrimary))
            }
            .frame(maxHeight: .infinity)

        case .offline:
            ContentUnavailableView {
                Label("Image Not Downloaded", systemImage: "wifi.slash")
            } description: {
                Text("Connect to the internet to view this receipt.")
            }
            .frame(maxHeight: .infinity)

        case .noImage:
            ContentUnavailableView {
                Label("No Image", systemImage: "photo")
            } description: {
                Text("This receipt has no image.")
            }
            .frame(maxHeight: .infinity)
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
        .accessibilityLabel("Actions")
        .confirmationDialog("Actions", isPresented: $showActionsSheet, titleVisibility: .hidden) {
            Button("Edit Details") { showEditSheet = true }

            // Retry and page management act on local files. A mirrored row has
            // none, so there is nothing to retry or reorder — and the phone does
            // not destroy server records it had no part in creating.
            if !receipt.isRemote {
                if receipt.pages.count > 1 && (receipt.syncStatus == .queued || receipt.syncStatus == .failed) {
                    Button("Manage Pages") { showManagePages = true }
                }

                if receipt.syncStatus == .failed || receipt.syncStatus == .queued {
                    Button("Retry Upload") { syncService.retryReceipt(receipt) }
                }

                Button("Delete", role: .destructive) { showDeleteConfirm = true }
            }
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if removedFromServer {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(.statusWarningContent))
                        Text("This receipt was removed during review on the web. Your copy is still on this device.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.statusWarning).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }

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

                    if let pdfLabel {
                        Label(pdfLabel, systemImage: "doc.richtext")
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
                .foregroundStyle(Color(.statusError))
            VStack(alignment: .leading, spacing: 2) {
                Text("Rejected")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let reason = receipt.rejectionReason {
                    Text(ReceiptRowFormatting.rejectionReasonLabel(reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Remote Content

    /// Fetches detail and downloads any missing images. Safe to call on every
    /// appearance — pages that already have bytes are skipped.
    private func loadRemoteContentIfNeeded() async {
        guard let serverId = receipt.serverReceiptId else { return }
        let needsPages = ReceiptDetailContent.needsDetailFetch(receipt)
        let needsBytes = receipt.pages.contains { !$0.imageDownloaded }
        guard needsPages || needsBytes else { return }

        isLoadingImages = true
        defer { isLoadingImages = false }
        imageLoadError = nil

        if needsPages {
            switch await receiptListService.fetchDetail(
                serverReceiptId: serverId, accountId: receipt.accountId
            ) {
            case .ok:
                break
            case .removedFromServer:
                removedFromServer = true
                return
            case .deleted:
                // The mirrored row is gone; pop back before the body reads it.
                selectedReceipt = nil
                return
            case .cancelled:
                // The view went away mid-fetch. Nothing to show, nothing wrong.
                return
            case .failed(let message):
                imageLoadError = message
                return
            }
        }

        do {
            try await imageDownloader.downloadMissingImages(for: receipt)
        } catch {
            imageLoadError = error.localizedDescription
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
