//
//  ImageGalleryView.swift
//  JetLedger
//

import SwiftUI

struct ImageGalleryView: View {
    let pages: [LocalReceiptPage]
    @State private var currentPage = 0

    private var sortedPages: [LocalReceiptPage] {
        pages.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $currentPage) {
                ForEach(Array(sortedPages.enumerated()), id: \.element.id) { index, page in
                    pageView(for: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if sortedPages.count > 1 {
                pageIndicator
            }
        }
    }

    @ViewBuilder
    private func pageView(for page: LocalReceiptPage) -> some View {
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

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<sortedPages.count, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.bottom, 4)
    }
}
