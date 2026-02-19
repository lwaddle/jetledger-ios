//
//  PDFPageView.swift
//  JetLedger
//

import PDFKit
import SwiftUI

struct PDFPageView: UIViewRepresentable {
    let relativePath: String

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.backgroundColor = .systemBackground
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        let url = ImageUtils.documentsDirectory().appendingPathComponent(relativePath)
        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }
    }
}
