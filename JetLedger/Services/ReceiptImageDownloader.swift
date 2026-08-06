//
//  ReceiptImageDownloader.swift
//  JetLedger
//

import Foundation
import Observation
import OSLog
import SwiftData
import UIKit

/// Fetches receipt images the device doesn't have — receipts that arrived by
/// email or web upload, and local captures whose files retention has reclaimed.
///
/// The presigned download URL expires, so only bytes are cached, never the URL.
@Observable
class ReceiptImageDownloader {
    /// Receipts with a download in flight, so the detail view can show progress
    /// without owning the state itself.
    private(set) var inFlightReceiptIds: Set<UUID> = []

    /// The live download per receipt, so a second caller joins it instead of
    /// starting a duplicate.
    ///
    /// The task is unstructured on purpose: the caller's cancellation must not
    /// kill a download other callers are waiting on. The detail view's load is
    /// itself detached for the same reason — SwiftUI cancels `.task(id:)`
    /// during a navigation transition — which is exactly what makes a second
    /// request for an already-loading receipt reachable.
    private var inFlightDownloads: [UUID: Task<Void, Error>] = [:]

    private static let logger = Logger(subsystem: "io.jetledger.JetLedger", category: "ReceiptImageDownloader")
    private let receiptAPI: ReceiptAPIService
    private let modelContext: ModelContext
    private let session: URLSession

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    init(
        receiptAPI: ReceiptAPIService,
        modelContext: ModelContext,
        session: URLSession = ReceiptImageDownloader.makeDefaultSession()
    ) {
        self.receiptAPI = receiptAPI
        self.modelContext = modelContext
        self.session = session
    }

    /// Downloads every page that names a server object but has no bytes on disk.
    /// Pages already present are skipped, so this is safe to call on every open.
    ///
    /// A second call for a receipt already downloading awaits the first rather
    /// than issuing its own requests.
    func downloadMissingImages(for receipt: LocalReceipt) async throws {
        let receiptId = receipt.id
        if let existing = inFlightDownloads[receiptId] {
            try await existing.value
            return
        }

        let pending = receipt.pages
            .filter { !$0.imageDownloaded && $0.serverFilePath != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard !pending.isEmpty else { return }

        // Bookkeeping is cleared inside the task, not in the caller's `defer`:
        // a caller cancelled while awaiting must not deregister a download that
        // is still running, or the next caller starts a duplicate.
        let task = Task { [self] in
            defer {
                inFlightDownloads[receiptId] = nil
                inFlightReceiptIds.remove(receiptId)
            }
            try await performDownload(pending, receipt: receipt, receiptId: receiptId)
        }
        inFlightDownloads[receiptId] = task
        inFlightReceiptIds.insert(receiptId)
        try await task.value
    }

    private func performDownload(
        _ pending: [LocalReceiptPage],
        receipt: LocalReceipt,
        receiptId: UUID
    ) async throws {
        for page in pending {
            guard let filePath = page.serverFilePath else { continue }

            // The detail response now presigns each image, so the extra
            // download-url round trip is only needed when it didn't — or when
            // the presigned URL has aged out of the window the server signed it
            // for, which reads as absent so a retry gets a live grant rather
            // than spending the same dead one again.
            let url: URL
            if let presigned = page.serverImageId.flatMap({
                ReceiptMirror.presignedImageURL(forImageId: $0)
            }) {
                url = presigned
            } else {
                let grant = try await receiptAPI.getDownloadURL(filePath: filePath)
                guard let resolved = URL(string: grant.downloadUrl) else {
                    throw APIError.serverError(0)
                }
                url = resolved
            }
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw APIError.serverError(http.statusCode)
            }

            // ImageUtils owns the naming scheme and applies file protection on
            // write, so the destination path comes back from it rather than
            // being assembled here.
            let savedPath: String?
            switch page.contentType {
            case .pdf:
                savedPath = ImageUtils.saveReceiptPDF(
                    data: data, receiptId: receiptId, pageIndex: page.sortOrder
                )
                if savedPath != nil {
                    _ = ImageUtils.savePDFThumbnail(
                        pdfData: data, receiptId: receiptId, pageIndex: page.sortOrder
                    )
                }
            case .jpeg:
                savedPath = ImageUtils.saveReceiptImage(
                    data: data, receiptId: receiptId, pageIndex: page.sortOrder
                )
                // A thumbnail here is what lets the list row stop showing a
                // placeholder glyph for a receipt the user has opened.
                if savedPath != nil, let image = UIImage(data: data) {
                    _ = ImageUtils.saveThumbnail(
                        from: image, receiptId: receiptId, pageIndex: page.sortOrder
                    )
                }
            }

            guard let savedPath else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "Could not save the downloaded receipt image."
                ])
            }

            page.localImagePath = savedPath
            page.imageDownloaded = true
            page.imageDownloadedAt = Date()
            trySave()
        }

        // The receipt is no longer image-less, so the detail view's "Images
        // Removed" state must not reappear for it.
        receipt.imagesCleanedUp = false
        trySave()
    }

    private func trySave() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("SwiftData save failed: \(error.localizedDescription)")
        }
    }
}
