//
//  ImageProcessor.swift
//  JetLedger
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

struct DetectedRectangle: Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
    var confidence: Float
}

@Observable
class ImageProcessor {
    nonisolated let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Document Detection

    /// The segmentation request happily returns a quad for whatever it segments
    /// (a hand, a placemat); below this confidence, treat the frame as "no
    /// receipt" so the lock-on overlay doesn't chase junk.
    private nonisolated static let minimumDetectionConfidence: Float = 0.6

    /// ML-based document segmentation (the model behind the Notes scanner) —
    /// unlike `VNDetectRectanglesRequest` it handles crumpled thermal paper,
    /// low-contrast edges, long receipts, and partial occlusion.
    private nonisolated func mapResult(_ result: VNRectangleObservation) -> DetectedRectangle? {
        guard result.confidence >= Self.minimumDetectionConfidence else { return nil }
        return DetectedRectangle(
            topLeft: result.topLeft,
            topRight: result.topRight,
            bottomLeft: result.bottomLeft,
            bottomRight: result.bottomRight,
            confidence: result.confidence
        )
    }

    nonisolated func detectRectangle(in cgImage: CGImage) -> DetectedRectangle? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let result = request.results?.first else { return nil }
        return mapResult(result)
    }

    nonisolated func detectRectangle(in sampleBuffer: CMSampleBuffer) -> DetectedRectangle? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .right,
            options: [:]
        )
        try? handler.perform([request])

        guard let result = request.results?.first else { return nil }
        return mapResult(result)
    }

    // MARK: - Perspective Correction

    nonisolated func applyPerspectiveCorrection(
        to image: CGImage,
        corners: DetectedRectangle
    ) -> UIImage? {
        let ciImage = CIImage(cgImage: image)
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = CGPoint(x: corners.topLeft.x * w, y: corners.topLeft.y * h)
        filter.topRight = CGPoint(x: corners.topRight.x * w, y: corners.topRight.y * h)
        filter.bottomLeft = CGPoint(x: corners.bottomLeft.x * w, y: corners.bottomLeft.y * h)
        filter.bottomRight = CGPoint(x: corners.bottomRight.x * w, y: corners.bottomRight.y * h)

        guard let output = filter.outputImage,
              let cgResult = ciContext.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgResult)
    }

    // MARK: - Noise Reduction

    /// Applies conservative noise reduction — cleans sensor noise without softening text.
    nonisolated private func applyNoiseReduction(to image: CIImage) -> CIImage {
        let nr = CIFilter.noiseReduction()
        nr.inputImage = image
        nr.noiseLevel = 0.02
        nr.sharpness = 0.4
        return nr.outputImage ?? image
    }

    // MARK: - Enhancement

    /// CIDocumentEnhancer strength (0–10). 1.0 is Apple's default "scanned
    /// document" look: shadow removal, background whitening, text contrast —
    /// while keeping color, which matters for stamps and highlighted totals.
    private nonisolated static let documentEnhancerAmount: Float = 1.0

    nonisolated func enhance(_ image: UIImage, mode: EnhancementMode, exposureEV: Float = 0.0) -> UIImage? {
        guard mode.normalized != .original || exposureEV != 0.0 else { return image }
        guard let cgImage = image.cgImage else { return image }

        var ciImage = CIImage(cgImage: cgImage)

        if mode.normalized == .auto {
            // Noise reduction first — before enhancement amplifies noise
            ciImage = applyNoiseReduction(to: ciImage)

            // ML document cleanup — handles uneven illumination (e.g. the
            // phone's own shadow across the receipt), which the previous
            // global contrast/brightness pipeline could not.
            let enhancer = CIFilter.documentEnhancer()
            enhancer.inputImage = ciImage
            enhancer.amount = Self.documentEnhancerAmount
            guard let enhanced = enhancer.outputImage else { return image }
            ciImage = enhanced
        }

        if exposureEV != 0.0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = ciImage
            exposure.ev = exposureEV
            guard let exposed = exposure.outputImage else { return image }
            ciImage = exposed
        }

        guard let cgResult = ciContext.createCGImage(ciImage, from: ciImage.extent)
        else { return image }
        return UIImage(cgImage: cgResult)
    }

    // MARK: - Combined Pipeline

    nonisolated func processCapture(
        image: CGImage,
        corners: DetectedRectangle?,
        enhancement: EnhancementMode,
        exposureEV: Float = 0.0
    ) -> UIImage? {
        let corrected: UIImage
        if let corners {
            guard let result = applyPerspectiveCorrection(to: image, corners: corners) else {
                return nil
            }
            corrected = result
        } else {
            corrected = ImageUtils.resizeIfNeeded(UIImage(cgImage: image))
        }

        return enhance(corrected, mode: enhancement, exposureEV: exposureEV) ?? corrected
    }
}
