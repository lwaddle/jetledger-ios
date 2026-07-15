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
    // Only accessed on sessionQueue — safe for nonisolated access
    @ObservationIgnored
    nonisolated(unsafe) private var isConfigured = false
    // Written once in init, read in deinit — no concurrent access
    @ObservationIgnored
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []

    init() {
        observeSessionNotifications()
    }

    /// Without these, a phone call or Split View camera preemption freezes the
    /// preview with state stuck at .running and the shutter enabled, and an
    /// AVCaptureSession runtime error (e.g. media services reset) kills the
    /// session permanently while the UI still claims the camera is live.
    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: captureSession, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state = .failed("Camera is in use by another app")
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: captureSession, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startRunning()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // One restart attempt; if the session won't come back, surface it.
                self.sessionQueue.async {
                    if self.isConfigured, !self.captureSession.isRunning {
                        self.captureSession.startRunning()
                    }
                    let running = self.captureSession.isRunning
                    DispatchQueue.main.async {
                        self.state = running
                            ? .running
                            : .failed("Camera error — close and reopen the scanner")
                    }
                }
            }
        })
    }

    // MARK: - Configuration

    nonisolated func configure() {
        // Pre-warming from the main screen must not be the thing that fires the
        // camera TCC prompt (contextless) — and creating the device input while
        // undetermined/denied just fails. The capture flow requests permission
        // with context; startRunning() configures on demand once granted.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        sessionQueue.async { [self] in
            self.performConfiguration()
        }
    }

    private nonisolated func performConfiguration() {
        guard !isConfigured else { return }

        DispatchQueue.main.async {
            self.state = .configuring
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        // Prefer the dual-wide virtual device: on iPhone 13 Pro+ the bare wide
        // camera cannot focus closer than ~20cm, and the automatic switch to
        // the ultra-wide's macro mode only happens on virtual devices.
        // Receipts are held close — this is the difference between sharp text
        // and unrecoverable blur.
        let device = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let camera = device,
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
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()

        do {
            try camera.lockForConfiguration()

            // A virtual device's zoom factor 1.0 is the ultra-wide's field of
            // view; the switch-over factor is the classic 1x wide framing.
            // Without this the preview would open at 0.5x.
            if camera.isVirtualDevice,
               let switchOver = camera.virtualDeviceSwitchOverVideoZoomFactors.first {
                camera.videoZoomFactor = CGFloat(truncating: switchOver)
            }

            // Receipts are always near — skip the far half of the AF hunt.
            if camera.isAutoFocusRangeRestrictionSupported {
                camera.autoFocusRangeRestriction = .near
            }

            // Slight positive exposure bias to compensate for white-paper underexposure
            let bias: Float = 0.5
            let clamped = max(camera.minExposureTargetBias, min(bias, camera.maxExposureTargetBias))
            camera.setExposureTargetBias(clamped, completionHandler: nil)

            camera.unlockForConfiguration()
        } catch {
            // Non-fatal — continue without zoom/focus/exposure tuning
        }

        isConfigured = true
        DispatchQueue.main.async {
            self.state = .ready
        }
    }

    // MARK: - Session Control

    func startRunning() {
        cancelScheduledStop()
        sessionQueue.async { [self] in
            // Configure on demand — covers the first-run path where permission
            // was granted inside the capture flow after the MainView pre-warm
            // was skipped (or a previous configuration attempt failed).
            if !isConfigured {
                performConfiguration()
            }
            // Never report .running for a session that has no inputs: the
            // warming overlay would clear over a black preview and the shutter
            // would reach capturePhoto with an empty supportedFlashModes — a
            // documented NSInvalidArgumentException. state stays .failed from
            // performConfiguration so the UI can say so.
            guard isConfigured else { return }
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

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        // Drain pending session work and tear the capture pipeline down
        // gracefully so AVFoundation closes its XPC channels cleanly.
        // Without this, dropping the manager (e.g. on sign-out / MainView
        // teardown) emits FigXPCUtilities err=-17281 / FigCaptureSourceRemote
        // bail noise. sessionQueue is necessarily idle here — every block
        // that enqueued onto it captured [self] strongly.
        sessionQueue.sync {
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            captureSession.beginConfiguration()
            for input in captureSession.inputs {
                captureSession.removeInput(input)
            }
            for output in captureSession.outputs {
                captureSession.removeOutput(output)
            }
            captureSession.commitConfiguration()
        }
    }
}
