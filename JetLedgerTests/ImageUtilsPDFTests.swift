//
//  ImageUtilsPDFTests.swift
//  JetLedgerTests
//

import Foundation
import Testing
import UIKit
@testable import JetLedger

struct ImageUtilsPDFTests {

    private func makePDFData(pageCount: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            for page in 1...pageCount {
                ctx.beginPage()
                ("Page \(page)" as NSString).draw(
                    at: CGPoint(x: 72, y: 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24)]
                )
            }
        }
    }

    @Test func countsPagesOfSavedPDF() throws {
        let receiptId = UUID()
        defer { ImageUtils.deleteReceiptImages(receiptId: receiptId) }

        let path = try #require(ImageUtils.saveReceiptPDF(
            data: makePDFData(pageCount: 3),
            receiptId: receiptId,
            pageIndex: 0
        ))

        #expect(ImageUtils.pdfPageCount(relativePath: path) == 3)
    }

    @Test func singlePagePDFCountsOne() throws {
        let receiptId = UUID()
        defer { ImageUtils.deleteReceiptImages(receiptId: receiptId) }

        let path = try #require(ImageUtils.saveReceiptPDF(
            data: makePDFData(pageCount: 1),
            receiptId: receiptId,
            pageIndex: 0
        ))

        #expect(ImageUtils.pdfPageCount(relativePath: path) == 1)
    }

    @Test func missingFileReturnsNil() {
        #expect(ImageUtils.pdfPageCount(relativePath: "receipts/nonexistent/page-001.pdf") == nil)
    }

    @Test func nonPDFFileReturnsNil() throws {
        let receiptId = UUID()
        defer { ImageUtils.deleteReceiptImages(receiptId: receiptId) }

        let jpeg = try #require(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
            .image { _ in }.jpegData(compressionQuality: 0.8))
        let path = try #require(ImageUtils.saveReceiptImage(
            data: jpeg,
            receiptId: receiptId,
            pageIndex: 0
        ))

        #expect(ImageUtils.pdfPageCount(relativePath: path) == nil)
    }
}
