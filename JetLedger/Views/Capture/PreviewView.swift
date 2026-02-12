//
//  PreviewView.swift
//  JetLedger
//

import SwiftUI

struct PreviewView: View {
    let coordinator: CaptureFlowCoordinator
    let onClose: () -> Void

    @State private var enhancementMode: EnhancementMode
    @State private var showDiscardAlert = false

    init(coordinator: CaptureFlowCoordinator, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onClose = onClose
        self._enhancementMode = State(initialValue: coordinator.currentCapture?.enhancementMode ?? .auto)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button {
                    if coordinator.pages.isEmpty {
                        onClose()
                    } else {
                        showDiscardAlert = true
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }

                Button {
                    coordinator.retake()
                } label: {
                    Label("Retake", systemImage: "arrow.uturn.backward")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                Spacer()

                if !coordinator.pages.isEmpty {
                    Text("Page \(coordinator.pages.count + 1)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    coordinator.acceptCurrentPage()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                }
            }
            .padding()

            Divider()

            // Image preview
            ZStack {
                if let image = coordinator.currentCapture?.processedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else {
                    ProgressView("Processing...")
                }

                if coordinator.isProcessing {
                    Color.black.opacity(0.3)
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Bottom controls
            VStack(spacing: 16) {
                EnhancementModePicker(selectedMode: $enhancementMode)
                    .onChange(of: enhancementMode) { _, newMode in
                        coordinator.changeEnhancement(to: newMode)
                    }

                Button {
                    coordinator.openCropAdjust()
                } label: {
                    Label("Adjust Corners", systemImage: "crop")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
            }
            .padding()
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
