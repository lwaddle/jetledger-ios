//
//  CameraView.swift
//  JetLedger
//

import PhotosUI
import SwiftUI
import UIKit

// MARK: - UIViewControllerRepresentable

struct CameraRepresentable: UIViewControllerRepresentable {
    let coordinator: CaptureFlowCoordinator

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.delegate = context.coordinator
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

// MARK: - SwiftUI View

struct CameraView: View {
    let coordinator: CaptureFlowCoordinator
    let onClose: () -> Void

    @State private var cameraVC: CameraViewController?
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        ZStack {
            // Camera preview
            CameraRepresentableWrapper(coordinator: coordinator, cameraVC: $cameraVC)
                .ignoresSafeArea()

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
                  let uiImage = UIImage(data: data),
                  let cgImage = uiImage.cgImage
            else { return }
            coordinator.handleCapturedImage(cgImage)
        }
    }
}

// MARK: - Camera Wrapper (to capture VC reference)

private struct CameraRepresentableWrapper: UIViewControllerRepresentable {
    let coordinator: CaptureFlowCoordinator
    @Binding var cameraVC: CameraViewController?

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
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
