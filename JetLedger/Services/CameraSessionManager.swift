//
//  CameraSessionManager.swift
//  JetLedger
//

import AVFoundation

@Observable
class CameraSessionManager {
    private(set) var state: CameraSessionState = .idle

    nonisolated(unsafe) let captureSession = AVCaptureSession()
    nonisolated(unsafe) let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) let videoOutput = AVCaptureVideoDataOutput()
    let imageProcessor = ImageProcessor()

    nonisolated let sessionQueue = DispatchQueue(label: "com.jetledger.camera.session")

    private var stopWorkItem: DispatchWorkItem?
    private var isConfigured = false

    // MARK: - Configuration

    nonisolated func configure() {
        sessionQueue.async { [self] in
            self.performConfiguration()
        }
    }

    private nonisolated func performConfiguration() {
        var alreadyConfigured = false
        DispatchQueue.main.sync {
            alreadyConfigured = isConfigured
        }
        guard !alreadyConfigured else { return }

        DispatchQueue.main.async {
            self.state = .configuring
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera)
        else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.state = .failed("Camera not available")
            }
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()

        DispatchQueue.main.async {
            self.isConfigured = true
            self.state = .ready
        }
    }

    // MARK: - Session Control

    func startRunning() {
        cancelScheduledStop()
        sessionQueue.async { [self] in
            guard !self.captureSession.isRunning else {
                DispatchQueue.main.async {
                    self.state = .running
                }
                return
            }
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.state = .running
            }
        }
    }

    func stopRunning() {
        sessionQueue.async { [self] in
            guard self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
            DispatchQueue.main.async {
                if self.isConfigured {
                    self.state = .ready
                }
            }
        }
    }

    func scheduleStop(after seconds: TimeInterval = 30) {
        cancelScheduledStop()
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopRunning()
        }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    func cancelScheduledStop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
    }
}
