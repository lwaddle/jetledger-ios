//
//  CameraView.swift
//  JetLedger
//

import PhotosUI
import SwiftUI
import UIKit

// MARK: - SwiftUI View

struct CameraView: View {
    let coordinator: CaptureFlowCoordinator
    let cameraSessionManager: CameraSessionManager
    let onClose: () -> Void

    @State private var cameraVC: CameraViewController?
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            // Camera preview
            CameraRepresentableWrapper(
                coordinator: coordinator,
                cameraSessionManager: cameraSessionManager,
                cameraVC: $cameraVC
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
                Spacer()
                if coordinator.isDetectionStable {
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
        .animation(.easeInOut(duration: 0.3), value: coordinator.isDetectionStable)
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
        }
        .padding(.horizontal)
        .padding(.top, 8)
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
            .onChange(of: selectedPhotos) { _, newItems in
                handlePhotoSelection(newItems)
            }

            // Shutter button
            Button {
                cameraVC?.capturePhoto()
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

            // Spacer to balance layout
            Color.clear
                .frame(width: 50, height: 50)
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
                let renderer = UIGraphicsImageRenderer(size: uiImage.size)
                let normalized = renderer.image { _ in uiImage.draw(at: .zero) }
                guard let cg = normalized.cgImage else { return }
                cgImage = cg
            }
            coordinator.handleCapturedImage(cgImage)
        }
    }
}

// MARK: - Camera Wrapper (to capture VC reference)

private struct CameraRepresentableWrapper: UIViewControllerRepresentable {
    let coordinator: CaptureFlowCoordinator
    let cameraSessionManager: CameraSessionManager
    @Binding var cameraVC: CameraViewController?

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.attachSessionManager(cameraSessionManager)
        vc.delegate = context.coordinator
        DispatchQueue.main.async {
            cameraVC = vc
        }
        vc.startSession()
        return vc
    }

    func updateUIViewController(_ vc: CameraViewController, context: Context) {
        vc.isFlashOn = coordinator.isFlashOn
    }

    static func dismantleUIViewController(_ vc: CameraViewController, coordinator: Coordinator) {
        vc.stopSession()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(flowCoordinator: coordinator)
    }

    class Coordinator: NSObject, CameraViewControllerDelegate {
        let flowCoordinator: CaptureFlowCoordinator

        init(flowCoordinator: CaptureFlowCoordinator) {
            self.flowCoordinator = flowCoordinator
        }

        func cameraDidCapture(image: CGImage) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            flowCoordinator.handleCapturedImage(image)
        }

        func cameraDidUpdateDetection(_ rect: DetectedRectangle?) {
            flowCoordinator.liveDetectedRect = rect
        }

        func cameraDidBecomeStable(_ stable: Bool) {
            flowCoordinator.isDetectionStable = stable
            if stable {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }

        func cameraDidFail(error: String) {
            flowCoordinator.error = error
        }
    }
}
