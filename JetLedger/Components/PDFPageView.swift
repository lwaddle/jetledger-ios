//
//  PDFPageView.swift
//  JetLedger
//

import PDFKit
import SwiftUI

struct PDFPageView: UIViewRepresentable {
    let relativePath: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        // Continuous vertical scroll so every page of a multi-page PDF is
        // reachable. (.singlePage pins PDFKit to page 1 with no navigation,
        // and horizontal paging would fight the gallery TabView's swipe.)
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .systemBackground
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        guard context.coordinator.loadedPath != relativePath else { return }
        let url = ImageUtils.documentsDirectory().appendingPathComponent(relativePath)
        if let document = PDFDocument(url: url) {
            pdfView.document = document
            context.coordinator.loadedPath = relativePath
        }
    }

    class Coordinator {
        var loadedPath: String?
    }
}
