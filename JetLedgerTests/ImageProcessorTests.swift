//
//  ImageProcessorTests.swift
//  JetLedgerTests
//

import Testing
import UIKit
@testable import JetLedger

@MainActor
struct ImageProcessorTests {

    private func makeReceiptLikeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // Text-like dark lines so the document enhancer has content to work on
            UIColor.black.setFill()
            for y in stride(from: 40, to: Int(size.height) - 40, by: 40) {
                ctx.fill(CGRect(x: 40, y: CGFloat(y), width: size.width - 80, height: 6))
            }
        }
    }

    /// The preview swaps Original/Auto renditions of the same capture in and
    /// out of one image view — if enhancement changes the pixel dimensions,
    /// the swap causes a visible layout jump (and a silently multiplied
    /// memory footprint held until save).
    @Test func autoEnhanceKeepsPixelDimensions() {
        let input = makeReceiptLikeImage(size: CGSize(width: 600, height: 900))
        let processor = ImageProcessor()

        let output = processor.enhance(input, mode: .auto)

        #expect(output != nil)
        if let output {
            print("ImageProcessorTests: input \(input.size) → auto-enhanced \(output.size)")
            #expect(output.size == input.size)
        }
    }

    /// Same invariant through the real capture path at camera resolution:
    /// Original and Auto renditions of one capture must have identical pixel
    /// dimensions, or toggling modes shifts layout in the preview.
    @Test func originalAndAutoRenditionsMatchInSize() {
        let input = makeReceiptLikeImage(size: CGSize(width: 3024, height: 4032))
        guard let cgImage = input.cgImage else {
            Issue.record("Failed to create test image")
            return
        }
        let corners = DetectedRectangle(
            topLeft: CGPoint(x: 0.1, y: 0.9),
            topRight: CGPoint(x: 0.9, y: 0.9),
            bottomLeft: CGPoint(x: 0.1, y: 0.1),
            bottomRight: CGPoint(x: 0.9, y: 0.1),
            confidence: 1.0
        )
        let processor = ImageProcessor()

        let original = processor.processCapture(image: cgImage, corners: corners, enhancement: .original)
        let auto = processor.processCapture(image: cgImage, corners: corners, enhancement: .auto)

        #expect(original != nil)
        #expect(auto != nil)
        if let original, let auto {
            print("ImageProcessorTests: original \(original.size) vs auto \(auto.size), scales \(original.scale)/\(auto.scale)")
            #expect(original.size == auto.size)
            #expect(original.scale == auto.scale)
        }
    }
}
