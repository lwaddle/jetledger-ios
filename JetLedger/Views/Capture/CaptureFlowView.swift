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
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    cameraPermission = granted ? .authorized : .denied
                }
            }

            if coordinator == nil && cameraPermission != .denied && cameraPermission != .restricted {
                let mode = EnhancementMode(rawValue: defaultEnhancementRaw) ?? .auto
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
            .tint(AppConstants.Colors.primaryAccent)

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
                dismiss()
            }

        case .preview:
            PreviewView(coordinator: coordinator) {
                dismiss()
            }

        case .cropAdjust:
            CropAdjustView(coordinator: coordinator) {
                dismiss()
            }

        case .multiPagePrompt:
            MultiPagePromptView(coordinator: coordinator) {
                dismiss()
            }

        case .metadata:
            MetadataView(coordinator: coordinator, onDone: {
                dismiss()
            }, onClose: {
                dismiss()
            })
        }
    }
}

// MARK: - Multi-Page Prompt

private struct MultiPagePromptView: View {
    let coordinator: CaptureFlowCoordinator
    let onClose: () -> Void

    @State private var showDiscardAlert = false

    var body: some View {
        VStack(spacing: 24) {
            // Close button
            HStack {
                Button {
                    showDiscardAlert = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            // Page thumbnails
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(coordinator.pages) { page in
                        if let image = page.processedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.secondary.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal)
            }

            Text("\(coordinator.pages.count) page\(coordinator.pages.count == 1 ? "" : "s") captured")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Add another page?")
                .font(.body)
                .foregroundStyle(.secondary)

            // Actions
            VStack(spacing: 12) {
                Button {
                    coordinator.addAnotherPage()
                } label: {
                    Label("Add Another Page", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Button {
                    coordinator.proceedToMetadata()
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppConstants.Colors.primaryAccent)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .background(Color(.systemBackground))
        .alert("Discard Receipt?", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(coordinator.pages.count) captured page\(coordinator.pages.count == 1 ? "" : "s") will be discarded.")
        }
    }
}
