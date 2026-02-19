//
//  ImageUtils.swift
//  JetLedger
//

import AVFoundation
import CoreGraphics
import UIKit

nonisolated enum ImageUtils {

    // MARK: - Directory Helpers

    static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func receiptDirectory(receiptId: UUID) -> URL {
        documentsDirectory().appendingPathComponent("receipts/\(receiptId.uuidString)")
    }

    // MARK: - Resize

    static func resizeIfNeeded(_ image: UIImage, maxDimension: CGFloat = 4096) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }

        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - JPEG Compression

    static func compressToJPEG(
        _ image: UIImage,
        quality: CGFloat = 0.8,
        maxFileSize: Int = 10 * 1024 * 1024
    ) -> Data? {
        var currentQuality = quality
        while currentQuality > 0.1 {
            guard let data = image.jpegData(compressionQuality: currentQuality) else { return nil }
            if data.count <= maxFileSize { return data }
            currentQuality -= 0.1
        }
        return image.jpegData(compressionQuality: 0.1)
    }

    // MARK: - Save / Load / Delete

    static func saveReceiptImage(data: Data, receiptId: UUID, pageIndex: Int) -> String? {
        let dir = receiptDirectory(receiptId: receiptId)
        let fileName = String(format: "page-%03d.jpg", pageIndex + 1)
        let relativePath = "receipts/\(receiptId.uuidString)/\(fileName)"

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(fileName))
            return relativePath
        } catch {
            return nil
        }
    }

    static func saveThumbnail(from image: UIImage, receiptId: UUID, pageIndex: Int) -> String? {
        let thumbSize = CGSize(width: 96, height: 128)
        let renderer = UIGraphicsImageRenderer(size: thumbSize)
        let thumbnail = renderer.image { _ in
            let scale = max(thumbSize.width / image.size.width, thumbSize.height / image.size.height)
            let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (thumbSize.width - scaledSize.width) / 2,
                y: (thumbSize.height - scaledSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }

        guard let data = thumbnail.jpegData(compressionQuality: 0.7) else { return nil }

        let dir = receiptDirectory(receiptId: receiptId)
        let fileName = String(format: "page-%03d-thumb.jpg", pageIndex + 1)
        let relativePath = "receipts/\(receiptId.uuidString)/\(fileName)"

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(fileName))
            return relativePath
        } catch {
            return nil
        }
    }

    static func loadReceiptImage(relativePath: String) -> UIImage? {
        let url = documentsDirectory().appendingPathComponent(relativePath)
        return UIImage(contentsOfFile: url.path)
    }

    static func deleteReceiptImages(receiptId: UUID) {
        let dir = receiptDirectory(receiptId: receiptId)
        try? FileManager.default.removeItem(at: dir)
    }

    static func deletePageImage(relativePath: String) {
        let fullURL = documentsDirectory().appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: fullURL)
        // Delete thumbnail — works for both .jpg and .pdf source files
        let thumbPath = thumbnailPath(for: relativePath)
        let thumbURL = documentsDirectory().appendingPathComponent(thumbPath)
        try? FileManager.default.removeItem(at: thumbURL)
    }

    /// Canonical thumbnail path: strips extension, appends `-thumb.jpg`
    static func thumbnailPath(for imagePath: String) -> String {
        let base = (imagePath as NSString).deletingPathExtension
        return base + "-thumb.jpg"
    }

    // MARK: - PDF Support

    static func saveReceiptPDF(data: Data, receiptId: UUID, pageIndex: Int) -> String? {
        let dir = receiptDirectory(receiptId: receiptId)
        let fileName = String(format: "page-%03d.pdf", pageIndex + 1)
        let relativePath = "receipts/\(receiptId.uuidString)/\(fileName)"

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(fileName))
            return relativePath
        } catch {
            return nil
        }
    }

    static func savePDFThumbnail(pdfData: Data, receiptId: UUID, pageIndex: Int) -> String? {
        guard let thumbnail = renderPDFThumbnail(pdfData: pdfData, size: CGSize(width: 96, height: 128)) else {
            return nil
        }
        guard let jpegData = thumbnail.jpegData(compressionQuality: 0.7) else { return nil }

        let dir = receiptDirectory(receiptId: receiptId)
        let fileName = String(format: "page-%03d-thumb.jpg", pageIndex + 1)
        let relativePath = "receipts/\(receiptId.uuidString)/\(fileName)"

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try jpegData.write(to: dir.appendingPathComponent(fileName))
            return relativePath
        } catch {
            return nil
        }
    }

    static func renderPDFThumbnail(pdfData: Data, size: CGSize, pageNumber: Int = 1) -> UIImage? {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: pageNumber)
        else { return nil }

        let pageRect = page.getBoxRect(.mediaBox)
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let scaledSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        let renderer = UIGraphicsImageRenderer(size: scaledSize, format: format)

        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: scaledSize))

            let cgContext = ctx.cgContext
            cgContext.translateBy(x: 0, y: scaledSize.height)
            cgContext.scaleBy(x: scale, y: -scale)
            cgContext.drawPDFPage(page)
        }
    }

    static func loadFileData(relativePath: String) -> Data? {
        let url = documentsDirectory().appendingPathComponent(relativePath)
        return try? Data(contentsOf: url)
    }
}
