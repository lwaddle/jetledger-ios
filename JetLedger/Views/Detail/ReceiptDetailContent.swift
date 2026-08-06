//
//  ReceiptDetailContent.swift
//  JetLedger
//

import Foundation

/// Decides whether a receipt's images are still recoverable, and what an
/// image-less receipt is allowed to say. Pure functions so the rules can be
/// tested without standing up a view, matching `ReceiptRowFormatting`.
enum ReceiptDetailContent {

    /// What the detail view shows when no page has bytes on disk.
    enum EmptyState: Equatable {
        /// Online, and the server has a copy: a download should have happened
        /// and did not. Offer a retry rather than an explanation.
        case retryable
        /// Offline. The bytes exist on the server and will arrive with signal.
        case offline
        /// There is nothing anywhere to fetch — never uploaded, or the server
        /// reports no images for it. The only terminal case.
        case noImage
    }

    /// Whether `GET /api/receipts/{id}` should run before attempting a download.
    ///
    /// The last clause is load-bearing. `serverFilePath` is written only by
    /// `ReceiptMirror.upsertDetail`, and `ReceiptImageDownloader` silently skips
    /// any page without one. Keying the refetch on `detailFetchedAt == nil`
    /// alone left a dead end: a row whose detail was fetched once without
    /// acquiring file paths could never fetch again, never acquire them, and
    /// never download — it showed "Images Removed" permanently, online, with
    /// the bytes sitting in R2.
    ///
    /// The middle clause covers the same hole from the other side: the server
    /// says this receipt has images and there are no page records to download
    /// into, so the detail response is the only thing that can create them.
    /// Both are bounded by `imageCount` so a receipt that genuinely has no
    /// images does not refetch on every open.
    static func needsDetailFetch(_ receipt: LocalReceipt) -> Bool {
        if receipt.detailFetchedAt == nil { return true }
        if receipt.pages.isEmpty { return receipt.imageCount > 0 }
        return receipt.pages.contains { !$0.imageDownloaded && $0.serverFilePath == nil }
    }

    /// Reachable only when no page has bytes. Reads connectivity rather than
    /// retention: the user cannot act on "we reclaimed your disk", and being
    /// told so about a receipt whose image is one request away is worse than
    /// useless — it reads as data loss.
    static func emptyState(for receipt: LocalReceipt, isConnected: Bool) -> EmptyState {
        guard receipt.serverReceiptId != nil else { return .noImage }
        // Detail came back and the server reported no images. A Try Again
        // button here would promise something that cannot happen.
        if receipt.detailFetchedAt != nil, receipt.pages.isEmpty, receipt.imageCount == 0 {
            return .noImage
        }
        return isConnected ? .retryable : .offline
    }

    /// Whether a network attempt could accomplish anything for this receipt.
    /// Consolidates what were three separate guards in the detail view
    /// (connectivity, `serverReceiptId` presence, and whether anything is
    /// actually missing) into one tested precondition.
    ///
    /// The connectivity clause matters on its own: offline, attempting the
    /// call fails with a raw `URLError`, which sets `imageLoadError` — and
    /// the "Couldn't Load Images" branch in the view's if/else-if chain sits
    /// above the empty-state branch, so it wins and stays on screen (nothing
    /// clears `imageLoadError` while still offline). That defeats the point
    /// of `emptyState`: a purpose-built ".offline" case exists precisely so
    /// a disconnected user sees "Connect to the internet" instead of a raw
    /// network error. Refusing to try in the first place keeps
    /// `imageLoadError` nil so `emptyState` can render. Matches the existing
    /// `ReceiptListService.fetchPage` pattern of
    /// `guard networkMonitor.isConnected else { return [] }`.
    static func shouldAttemptFetch(_ receipt: LocalReceipt, isConnected: Bool) -> Bool {
        guard isConnected else { return false }
        guard receipt.serverReceiptId != nil else { return false }
        return needsDetailFetch(receipt) || receipt.pages.contains { !$0.imageDownloaded }
    }
}
