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
}

class CameraViewController: UIViewController {
    weak var delegate: CameraViewControllerDelegate?

    var isFlashOn = false

    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.jetledger.camera.processing")
    private var previewLayer: AVCaptureVideoPreviewLayer!

    private let overlayLayer = CAShapeLayer()
    private let imageProcessor = ImageProcessor()
    private var lastStableRect: DetectedRectangle?
    private var stableStartTime: Date?
    private let stabilityThreshold: TimeInterval = 0.5
    private let positionThreshold: CGFloat = 0.02
    private var isCurrentlyStable = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera)
        else {
            delegate?.cameraDidFail(error: "Camera not available")
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
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

    // MARK: - Session Control

    func startSession() {
        guard !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    func stopSession() {
        guard captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    // MARK: - Capture

    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           device.hasFlash {
            settings.flashMode = isFlashOn ? .on : .off
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Overlay Update

    private func updateOverlay(with rect: DetectedRectangle?, stable: Bool) {
        guard let rect, let previewLayer else {
            overlayLayer.path = nil
            return
        }

        let tl = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: rect.topLeft.x, y: 1 - rect.topLeft.y))
        let tr = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: rect.topRight.x, y: 1 - rect.topRight.y))
        let bl = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: rect.bottomLeft.x, y: 1 - rect.bottomLeft.y))
        let br = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: rect.bottomRight.x, y: 1 - rect.bottomRight.y))

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
        let rect = imageProcessor.detectRectangle(in: sampleBuffer)

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
              let cgImage = image.cgImage
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
}
