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
/// When far away, shows a lightweight placeholder. The outer ZStack is kept
/// constant across `isNearCurrent` transitions so the UIPageViewController
/// backing `TabView(.page)` sees a stable page identity during swipe —
/// otherwise SwiftUI swaps the root view type mid-gesture, which produces
/// AttributeGraph cycle warnings and an unsteady transition.
private struct LazyPageView: View {
    let page: LocalReceiptPage
    let isNearCurrent: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground)
            if isNearCurrent {
                pageContent
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
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
