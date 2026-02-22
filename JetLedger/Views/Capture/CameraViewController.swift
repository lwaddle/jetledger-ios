//
//  CameraViewController.swift
//  JetLedger
//

import AVFoundation
import UIKit
import Vision

protocol CameraViewControllerDelegate: AnyObject {
    func cameraDidCapture(image: CGImage)
    func cameraDidUpdateDetection(_ rect: DetectedRectangle?)
    func cameraDidBecomeStable(_ stable: Bool)
    func cameraDidFail(error: String)
    func cameraDidDetectLowLight(_ isLowLight: Bool)
}

class CameraViewController: UIViewController {
    weak var delegate: CameraViewControllerDelegate?

    var isFlashOn = false

    nonisolated(unsafe) var sessionManager: CameraSessionManager!
    nonisolated(unsafe) private var _imageProcessor: ImageProcessor!

    private let processingQueue = DispatchQueue(label: "com.jetledger.camera.processing")
    private var previewLayer: AVCaptureVideoPreviewLayer!

    private let overlayLayer = CAShapeLayer()
    private var lastStableRect: DetectedRectangle?
    private var stableStartTime: Date?
    private let stabilityThreshold: TimeInterval = 0.5
    private let positionThreshold: CGFloat = 0.03
    private var isCurrentlyStable = false
    private var lastDetectionTime: CFAbsoluteTime = 0
    private let detectionInterval: CFAbsoluteTime = 0.1  // ~10 fps for detection
    private var isLowLight = false
    private var lastLightCheckTime = Date.distantPast

    // MARK: - Setup

    func attachSessionManager(_ manager: CameraSessionManager) {
        sessionManager = manager
        _imageProcessor = manager.imageProcessor
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPreviewLayer()
        setupOverlay()
        attachSampleBufferDelegate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - Camera Setup

    private func setupPreviewLayer() {
        previewLayer = AVCaptureVideoPreviewLayer(session: sessionManager.captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
    }

    private func setupOverlay() {
        overlayLayer.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
        overlayLayer.strokeColor = UIColor.systemBlue.cgColor
        overlayLayer.lineWidth = 2.0
        overlayLayer.lineDashPattern = [8, 4]
        view.layer.addSublayer(overlayLayer)
    }

    private func attachSampleBufferDelegate() {
        sessionManager.videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
    }

    // MARK: - Session Control

    func startSession() {
        sessionManager.cancelScheduledStop()
        sessionManager.startRunning()
    }

    func stopSession() {
        sessionManager.videoOutput.setSampleBufferDelegate(nil, queue: nil)
    }

    // MARK: - Capture

    func capturePhoto() {
        guard sessionManager.captureSession.isRunning else { return }
        let settings = AVCapturePhotoSettings()
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           device.hasFlash {
            settings.flashMode = isFlashOn ? .on : .off
        }
        sessionManager.photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Overlay Update

    private func updateOverlay(with rect: DetectedRectangle?, stable: Bool) {
        guard let rect, let previewLayer, previewLayer.frame.width > 0, previewLayer.frame.height > 0 else {
            overlayLayer.path = nil
            return
        }

        let tl = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 1 - rect.topLeft.y, y: rect.topLeft.x))
        let tr = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 1 - rect.topRight.y, y: rect.topRight.x))
        let bl = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 1 - rect.bottomLeft.y, y: rect.bottomLeft.x))
        let br = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 1 - rect.bottomRight.y, y: rect.bottomRight.x))

        let path = UIBezierPath()
        path.move(to: tl)
        path.addLine(to: tr)
        path.addLine(to: br)
        path.addLine(to: bl)
        path.close()

        overlayLayer.path = path.cgPath
        overlayLayer.strokeColor = stable ? UIColor.systemGreen.cgColor : UIColor.systemBlue.cgColor
        overlayLayer.fillColor = stable
            ? UIColor.systemGreen.withAlphaComponent(0.1).cgColor
            : UIColor.white.withAlphaComponent(0.1).cgColor
        overlayLayer.lineDashPattern = stable ? nil : [8, 4]
    }

    // MARK: - Stability Check

    private func checkStability(_ newRect: DetectedRectangle?) -> Bool {
        guard let newRect, let lastStable = lastStableRect else { return false }

        let dTL = distance(newRect.topLeft, lastStable.topLeft)
        let dTR = distance(newRect.topRight, lastStable.topRight)
        let dBL = distance(newRect.bottomLeft, lastStable.bottomLeft)
        let dBR = distance(newRect.bottomRight, lastStable.bottomRight)

        return max(dTL, dTR, dBL, dBR) < positionThreshold
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDetectionTime >= detectionInterval else { return }
        lastDetectionTime = now

        let rect = _imageProcessor.detectRectangle(in: sampleBuffer)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let rect {
                if checkStability(rect) {
                    if let start = stableStartTime {
                        let stable = Date().timeIntervalSince(start) >= stabilityThreshold
                        if stable != isCurrentlyStable {
                            isCurrentlyStable = stable
                            delegate?.cameraDidBecomeStable(stable)
                        }
                    } else {
                        stableStartTime = Date()
                    }
                } else {
                    lastStableRect = rect
                    stableStartTime = Date()
                    if isCurrentlyStable {
                        isCurrentlyStable = false
                        delegate?.cameraDidBecomeStable(false)
                    }
                }
            } else {
                lastStableRect = nil
                stableStartTime = nil
                if isCurrentlyStable {
                    isCurrentlyStable = false
                    delegate?.cameraDidBecomeStable(false)
                }
            }

            delegate?.cameraDidUpdateDetection(rect)
            updateOverlay(with: rect, stable: isCurrentlyStable)

            // Check light level every ~1 second
            if Date().timeIntervalSince(self.lastLightCheckTime) >= 1.0 {
                self.lastLightCheckTime = Date()
                if let input = self.sessionManager.captureSession.inputs.first as? AVCaptureDeviceInput {
                    let lowLight = input.device.iso > 400
                    if lowLight != self.isLowLight {
                        self.isLowLight = lowLight
                        self.delegate?.cameraDidDetectLowLight(lowLight)
                    }
                }
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.cameraDidFail(error: error.localizedDescription)
            }
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data),
              let cgImage = Self.normalizedCGImage(from: image)
        else {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.cameraDidFail(error: "Failed to process captured photo")
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.cameraDidCapture(image: cgImage)
        }
    }

    private nonisolated static func normalizedCGImage(from image: UIImage) -> CGImage? {
        guard image.imageOrientation != .up else { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let normalized = renderer.image { _ in image.draw(at: .zero) }
        return normalized.cgImage
    }
}
