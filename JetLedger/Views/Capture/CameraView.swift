//
//  CameraView.swift
//  JetLedger
//

import PhotosUI
import SwiftUI
import UIKit

// MARK: - Capture Proxy

/// Plain reference type (not @Observable) to hold the VC reference
/// without triggering SwiftUI state mutations during view construction.
class CaptureProxy {
    weak var cameraViewController: CameraViewController?
    func capturePhoto() { cameraViewController?.capturePhoto() }
}

// MARK: - SwiftUI View

struct CameraView: View {
    let coordinator: CaptureFlowCoordinator
    let cameraSessionManager: CameraSessionManager
    let onClose: () -> Void

    @State private var captureProxy = CaptureProxy()
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isDetectionStable = false
    @State private var isLowLight = false
    @State private var cameraError: String?

    var body: some View {
        ZStack {
            // Camera preview
            CameraRepresentableWrapper(
                coordinator: coordinator,
                cameraSessionManager: cameraSessionManager,
                captureProxy: captureProxy,
                onDetectionStableChanged: { stable in
                    isDetectionStable = stable
                },
                onLowLightChanged: { lowLight in
                    isLowLight = lowLight
                },
                onCameraError: { error in
                    cameraError = error
                }
            )
            .ignoresSafeArea()

            // Warming overlay — shown while camera session is starting
            if case .running = cameraSessionManager.state {
                // Camera is running, no overlay needed
            } else {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                            Text("Starting camera...")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .transition(.opacity)
            }

            // Controls overlay
            VStack {
                topBar
                if isLowLight && !coordinator.isFlashOn {
                    lowLightBanner
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                if isDetectionStable {
                    detectionIndicator
                        .transition(.opacity.combined(with: .scale))
                }
                Spacer()
                bottomBar
            }

            if coordinator.isProcessing {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isDetectionStable)
        .animation(.easeInOut(duration: 0.3), value: isLowLight)
        .animation(.easeInOut(duration: 0.3), value: coordinator.isFlashOn)
        .alert("Capture Error", isPresented: Binding(
            get: { cameraError != nil },
            set: { if !$0 { cameraError = nil } }
        )) {
            Button("OK") { cameraError = nil }
        } message: {
            Text(cameraError ?? "An unknown error occurred.")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            .accessibilityHint("Exits the camera without saving")

            Spacer()

            if !coordinator.pages.isEmpty {
                Text("Page \(coordinator.pages.count + 1)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            Button {
                coordinator.isFlashOn.toggle()
            } label: {
                Image(systemName: coordinator.isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.title3)
                    .foregroundStyle(coordinator.isFlashOn ? .yellow : .white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(coordinator.isFlashOn ? "Flash on" : "Flash off")
            .accessibilityHint("Toggles the camera flash")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Low Light Banner

    private var lowLightBanner: some View {
        Button {
            coordinator.isFlashOn = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.subheadline)
                Text("Low light — tap for flash")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.9), in: Capsule())
        }
    }

    // MARK: - Detection Indicator

    private var detectionIndicator: some View {
        Text("Receipt detected")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.green.opacity(0.8), in: Capsule())
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 40) {
            // Gallery picker
            PhotosPicker(
                selection: $selectedPhotos,
                maxSelectionCount: 10,
                matching: .images
            ) {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
            }
            .accessibilityLabel("Photo Library")
            .accessibilityHint("Select an image from your photo library")
            .onChange(of: selectedPhotos) { _, newItems in
                handlePhotoSelection(newItems)
            }

            // Shutter button
            Button {
                captureProxy.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 70, height: 70)
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 80, height: 80)
                }
            }
            .accessibilityLabel("Take Photo")
            .accessibilityHint("Captures the receipt image")

            // Spacer to balance layout
            Color.clear
                .frame(width: 50, height: 50)
                .accessibilityHidden(true)
        }
        .padding(.bottom, 30)
    }

    // MARK: - Photo Selection

    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard let first = items.first else { return }
        selectedPhotos = []

        Task {
            guard let data = try? await first.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data)
            else { return }
            let cgImage: CGImage
            if uiImage.imageOrientation == .up, let cg = uiImage.cgImage {
                cgImage = cg
            } else {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1.0
                let renderer = UIGraphicsImageRenderer(size: uiImage.size, format: format)
                let normalized = renderer.image { _ in uiImage.draw(at: .zero) }
                guard let cg = normalized.cgImage else { return }
                cgImage = cg
            }
            coordinator.handleCapturedImage(cgImage)
        }
    }
}

// MARK: - Camera Wrapper

private struct CameraRepresentableWrapper: UIViewControllerRepresentable {
    let coordinator: CaptureFlowCoordinator
    let cameraSessionManager: CameraSessionManager
    let captureProxy: CaptureProxy
    let onDetectionStableChanged: (Bool) -> Void
    let onLowLightChanged: (Bool) -> Void
    let onCameraError: (String) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.attachSessionManager(cameraSessionManager)
        vc.delegate = context.coordinator
        captureProxy.cameraViewController = vc
        vc.startSession()
        return vc
    }

    func updateUIViewController(_ vc: CameraViewController, context: Context) {
        vc.isFlashOn = coordinator.isFlashOn
        // Refresh closures so they capture current state
        context.coordinator.onDetectionStableChanged = onDetectionStableChanged
        context.coordinator.onLowLightChanged = onLowLightChanged
        context.coordinator.onCameraError = onCameraError
    }

    static func dismantleUIViewController(_ vc: CameraViewController, coordinator: Coordinator) {
        vc.stopSession()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            flowCoordinator: coordinator,
            onDetectionStableChanged: onDetectionStableChanged,
            onLowLightChanged: onLowLightChanged,
            onCameraError: onCameraError
        )
    }

    class Coordinator: NSObject, CameraViewControllerDelegate {
        let flowCoordinator: CaptureFlowCoordinator
        var onDetectionStableChanged: (Bool) -> Void
        var onLowLightChanged: (Bool) -> Void
        var onCameraError: (String) -> Void

        init(
            flowCoordinator: CaptureFlowCoordinator,
            onDetectionStableChanged: @escaping (Bool) -> Void,
            onLowLightChanged: @escaping (Bool) -> Void,
            onCameraError: @escaping (String) -> Void
        ) {
            self.flowCoordinator = flowCoordinator
            self.onDetectionStableChanged = onDetectionStableChanged
            self.onLowLightChanged = onLowLightChanged
            self.onCameraError = onCameraError
        }

        func cameraDidCapture(image: CGImage) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            flowCoordinator.handleCapturedImage(image)
        }

        func cameraDidUpdateDetection(_ rect: DetectedRectangle?) {
            // Overlay is handled by CameraViewController's CAShapeLayer directly
        }

        func cameraDidBecomeStable(_ stable: Bool) {
            onDetectionStableChanged(stable)
            if stable {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }

        func cameraDidFail(error: String) {
            onCameraError(error)
        }

        func cameraDidDetectLowLight(_ isLowLight: Bool) {
            onLowLightChanged(isLowLight)
        }
    }
}
