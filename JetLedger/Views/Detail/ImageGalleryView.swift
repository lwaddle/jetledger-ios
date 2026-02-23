//
//  ImageGalleryView.swift
//  JetLedger
//

import SwiftUI

struct ImageGalleryView: View {
    let sortedPages: [LocalReceiptPage]
    @State private var currentPage = 0

    init(pages: [LocalReceiptPage]) {
        self.sortedPages = pages.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $currentPage) {
                ForEach(Array(sortedPages.enumerated()), id: \.element.id) { index, page in
                    LazyPageView(
                        page: page,
                        isNearCurrent: abs(index - currentPage) <= 1
                    )
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if sortedPages.count > 1 {
                pageIndicator
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<sortedPages.count, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(currentPage + 1) of \(sortedPages.count)")
    }
}

/// Loads the full image only when the page is current or adjacent.
/// When far away, shows a lightweight placeholder.
private struct LazyPageView: View {
    let page: LocalReceiptPage
    let isNearCurrent: Bool

    var body: some View {
        if isNearCurrent {
            fullPageView
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var fullPageView: some View {
        if !page.imageDownloaded {
            RemotePageDownloadView(page: page)
        } else {
            switch page.contentType {
            case .pdf:
                PDFPageView(relativePath: page.localImagePath)
            case .jpeg:
                if let image = ImageUtils.loadReceiptImage(relativePath: page.localImagePath) {
                    ZoomableImageView(image: image)
                } else {
                    ContentUnavailableView(
                        "Image Not Found",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("The receipt image could not be loaded.")
                    )
                }
            }
        }
    }

    private var placeholder: some View {
        Color(.systemGroupedBackground)
            .overlay {
                ProgressView()
            }
    }
}

private struct RemotePageDownloadView: View {
    let page: LocalReceiptPage
    @Environment(SyncService.self) private var syncService
    @State private var isDownloading = false
    @State private var downloadFailed = false

    var body: some View {
        VStack(spacing: 16) {
            if isDownloading {
                ProgressView("Downloading...")
            } else if downloadFailed {
                ContentUnavailableView {
                    Label("Download Failed", systemImage: "exclamationmark.icloud")
                } description: {
                    Text("Could not download the receipt image.")
                } actions: {
                    Button("Retry") {
                        downloadFailed = false
                        startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task {
            if !page.imageDownloaded && !isDownloading {
                startDownload()
            }
        }
    }

    private func startDownload() {
        isDownloading = true
        Task {
            do {
                try await syncService.downloadPageImage(page)
            } catch {
                downloadFailed = true
            }
            isDownloading = false
        }
    }
}
