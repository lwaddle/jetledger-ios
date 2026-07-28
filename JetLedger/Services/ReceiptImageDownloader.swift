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
    func downloadMissingImages(for receipt: LocalReceipt) async throws {
        let pending = receipt.pages
            .filter { !$0.imageDownloaded && $0.serverFilePath != nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        guard !pending.isEmpty else { return }

        let receiptId = receipt.id
        inFlightReceiptIds.insert(receiptId)
        defer { inFlightReceiptIds.remove(receiptId) }

        for page in pending {
            guard let filePath = page.serverFilePath else { continue }

            // The detail response now presigns each image, so the extra
            // download-url round trip is only needed when it didn't.
            let url: URL
            if let presigned = page.serverImageId.flatMap({ ReceiptMirror.presignedImageURLs[$0] }) {
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
