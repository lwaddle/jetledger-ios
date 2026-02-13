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

    nonisolated func enhance(_ image: UIImage, mode: EnhancementMode) -> UIImage? {
        guard mode != .original else { return image }
        guard let cgImage = image.cgImage else { return image }

        var ciImage = CIImage(cgImage: cgImage)

        switch mode {
        case .original:
            return image

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
            let mono = CIFilter.colorMonochrome()
            mono.inputImage = ciImage
            mono.color = CIColor(red: 0.85, green: 0.85, blue: 0.85)
            mono.intensity = 1.0
            guard let step1 = mono.outputImage else { return image }

            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = step1
            colorControls.contrast = 1.4
            colorControls.brightness = 0.1
            colorControls.saturation = 0.0
            guard let step2 = colorControls.outputImage else { return image }

            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = step2
            sharpen.radius = 2.5
            sharpen.intensity = 0.5
            guard let step3 = sharpen.outputImage else { return image }
            ciImage = step3
        }

        guard let cgResult = ciContext.createCGImage(ciImage, from: ciImage.extent)
        else { return image }
        return UIImage(cgImage: cgResult)
    }

    // MARK: - Combined Pipeline

    nonisolated func processCapture(
        image: CGImage,
        corners: DetectedRectangle?,
        enhancement: EnhancementMode
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

        return enhance(corrected, mode: enhancement) ?? corrected
    }
}
