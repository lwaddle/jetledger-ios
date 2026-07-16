//
//  PreviewView.swift
//  JetLedger
//

import SwiftUI

struct PreviewView: View {
    let coordinator: CaptureFlowCoordinator
    let onClose: () -> Void

    @State private var enhancementMode: EnhancementMode
    @State private var showAdjustments = false
    @State private var showDiscardAlert = false

    init(coordinator: CaptureFlowCoordinator, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onClose = onClose
        self._enhancementMode = State(initialValue: coordinator.currentCapture?.enhancementMode.normalized ?? .auto)
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
                    Image(systemName: "xmark")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")

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
            }
            .padding()

            Divider()

            // Image preview
            ZStack {
                if let image = coordinator.currentCapture?.processedImage {
                    ZoomableImageView(image: image)
                } else {
                    ProgressView("Processing...")
                }

                // Compact badge, not a full-bleed dim: dimming the whole
                // container erases the image's letterbox boundary for the
                // duration of processing, which reads as the image jumping
                // to full width (visible on Auto, whose ML enhancement takes
                // ~1s; Original completes too fast to notice).
                if coordinator.isProcessing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                        .padding(16)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .frame(maxHeight: .infinity)
            // Floating overlay, NOT a layout sibling: the capsule toggles with
            // isProcessing, and as a VStack row its insertion/removal resizes
            // the greedy image container — the receipt visibly jumps toward
            // full width on every reprocess.
            .overlay(alignment: .bottom) {
                if let hint = hintText, !coordinator.isProcessing {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
                }
            }

            Divider()

            // Bottom controls — adjustments are tucked away; the 90% case is
            // glance at the auto result and tap Done.
            VStack(spacing: 12) {
                if showAdjustments {
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAdjustments.toggle()
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.headline)
                            .frame(width: 52)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Adjust image")
                    .accessibilityHint("Shows enhancement and crop controls")

                    Button {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        coordinator.acceptPageAndAddAnother()
                    } label: {
                        Label("Add Page", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        coordinator.acceptPageAndContinue()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                }
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

    private var hintText: String? {
        if coordinator.processingFailed {
            return "Auto-crop unavailable — showing original"
        }
        if coordinator.currentCapture?.detectedCorners == nil {
            return "Edges not detected — showing full photo"
        }
        return nil
    }
}
