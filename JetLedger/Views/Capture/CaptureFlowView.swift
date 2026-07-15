//
//  CaptureFlowView.swift
//  JetLedger
//

import AVFoundation
import SwiftData
import SwiftUI

struct CaptureFlowView: View {
    let accountId: UUID
    let cameraSessionManager: CameraSessionManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("defaultEnhancementMode") private var defaultEnhancementRaw = EnhancementMode.auto.rawValue
    @State private var coordinator: CaptureFlowCoordinator?
    @State private var cameraPermission: AVAuthorizationStatus = .notDetermined

    var body: some View {
        Group {
            switch cameraPermission {
            case .denied, .restricted:
                cameraPermissionDenied
            default:
                if let coordinator {
                    captureContent(coordinator)
                } else {
                    ProgressView()
                }
            }
        }
        .onAppear {
            cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)

            if cameraPermission == .notDetermined {
                // The completion runs on an arbitrary queue — hop back before
                // touching @State (background writes to SwiftUI state are
                // undefined behavior and trip Swift 6 isolation checks).
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    Task { @MainActor in
                        cameraPermission = granted ? .authorized : .denied
                    }
                }
            }

            if coordinator == nil && cameraPermission != .denied && cameraPermission != .restricted {
                let mode = (EnhancementMode(rawValue: defaultEnhancementRaw) ?? .auto).normalized
                coordinator = CaptureFlowCoordinator(
                    accountId: accountId,
                    defaultEnhancementMode: mode,
                    imageProcessor: cameraSessionManager.imageProcessor,
                    modelContext: modelContext
                )
            }
        }
        .interactiveDismissDisabled()
        .statusBarHidden(coordinator?.currentStep == .camera)
    }

    private var cameraPermissionDenied: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Camera Access Required",
                systemImage: "camera.slash",
                description: Text("JetLedger needs camera access to scan receipts. Enable it in Settings.")
            )

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)

            Button("Cancel") {
                dismiss()
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func captureContent(_ coordinator: CaptureFlowCoordinator) -> some View {
        switch coordinator.currentStep {
        case .camera:
            CameraView(coordinator: coordinator, cameraSessionManager: cameraSessionManager) {
                if coordinator.pages.isEmpty {
                    dismiss()
                } else {
                    // Backing out of "add another page" — the pages already
                    // accepted live on the metadata screen.
                    coordinator.proceedToMetadata()
                }
            }

        case .preview:
            PreviewView(coordinator: coordinator) {
                dismiss()
            }

        case .cropAdjust:
            CropAdjustView(coordinator: coordinator) {
                dismiss()
            }

        case .metadata:
            MetadataView(coordinator: coordinator, onDone: {
                dismiss()
            })
        }
    }
}
