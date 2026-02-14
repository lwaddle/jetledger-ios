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

    // MARK: - Rectangle Detection

    private nonisolated func makeRectangleRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.7
        request.minimumAspectRatio = 0.2
        request.minimumSize = 0.15
        request.quadratureTolerance = 15
        request.maximumObservations = 1
        return request
    }

    private nonisolated func mapResult(_ result: VNRectangleObservation) -> DetectedRectangle {
        DetectedRectangle(
            topLeft: result.topLeft,
            topRight: result.topRight,
            bottomLeft: result.bottomLeft,
            bottomRight: result.bottomRight,
            confidence: result.confidence
        )
    }

    nonisolated func detectRectangle(in cgImage: CGImage) -> DetectedRectangle? {
        let request = makeRectangleRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let result = request.results?.first else { return nil }
        return mapResult(result)
    }

    nonisolated func detectRectangle(in sampleBuffer: CMSampleBuffer) -> DetectedRectangle? {
        let request = makeRectangleRequest()
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

    // MARK: - Enhancement

    nonisolated func enhance(_ image: UIImage, mode: EnhancementMode, exposureEV: Float = 0.0) -> UIImage? {
        guard mode != .original || exposureEV != 0.0 else { return image }
        guard let cgImage = image.cgImage else { return image }

        var ciImage = CIImage(cgImage: cgImage)
        var exposureAppliedInPipeline = false

        switch mode {
        case .original:
            break

        case .auto:
            // Contrast + brightness
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = ciImage
            colorControls.contrast = 1.15
            colorControls.brightness = 0.02
            colorControls.saturation = 1.0
            guard let step1 = colorControls.outputImage else { return image }

            // Sharpen
            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = step1
            sharpen.radius = 2.5
            sharpen.intensity = 0.5
            guard let step2 = sharpen.outputImage else { return image }
            ciImage = step2

        case .blackAndWhite:
            // Step 1: High-contrast grayscale
            let grayscale = CIFilter.colorControls()
            grayscale.inputImage = ciImage
            grayscale.saturation = 0.0
            grayscale.brightness = 0.1
            grayscale.contrast = 3.5
            guard var bw = grayscale.outputImage else { return image }

            // Step 2: Exposure (shifts overall brightness before sharpening)
            if exposureEV != 0.0 {
                let exposure = CIFilter.exposureAdjust()
                exposure.inputImage = bw
                exposure.ev = exposureEV
                guard let exposed = exposure.outputImage else { return image }
                bw = exposed
                exposureAppliedInPipeline = true
            }

            // Step 3: Sharpen for crisp text edges
            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = bw
            sharpen.radius = 2.5
            sharpen.intensity = 0.5
            guard let sharpened = sharpen.outputImage else { return image }

            ciImage = sharpened
        }

        if exposureEV != 0.0 && !exposureAppliedInPipeline {
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
