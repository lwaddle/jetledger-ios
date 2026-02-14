//
//  CropAdjustView.swift
//  JetLedger
//

import SwiftUI

struct CropAdjustView: View {
    let coordinator: CaptureFlowCoordinator
    let onClose: () -> Void

    @State private var corners: [CornerPosition]
    @State private var activeCorner: Int?
    @State private var imageDisplayRect: CGRect = .zero
    @State private var showDiscardAlert = false

    private let originalImage: UIImage
    private let initialCorners: DetectedRectangle?

    init(coordinator: CaptureFlowCoordinator, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onClose = onClose

        let capture = coordinator.currentCapture
        let cgImage = capture?.originalImage
        self.originalImage = cgImage.map { UIImage(cgImage: $0) } ?? UIImage()
        self.initialCorners = capture?.detectedCorners

        // Initialize corner positions (will be recalculated in geometry)
        self._corners = State(initialValue: [
            CornerPosition(id: 0, point: .zero),
            CornerPosition(id: 1, point: .zero),
            CornerPosition(id: 2, point: .zero),
            CornerPosition(id: 3, point: .zero),
        ])
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

                Spacer()

                Text("Adjust Corners")
                    .font(.headline)

                Spacer()

                Button("Reset") {
                    resetCorners()
                }

                Button("Done") {
                    applyCorners()
                }
                .fontWeight(.semibold)
            }
            .padding()

            Divider()

            // Image with draggable corners
            GeometryReader { geometry in
                let rect = aspectFitRect(for: originalImage.size, in: geometry.size)

                ZStack {
                    // Original image
                    Image(uiImage: originalImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    // Dimming overlay
                    CropOverlay(corners: corners.map(\.point), bounds: geometry.size)
                        .fill(.black.opacity(0.4))
                        .allowsHitTesting(false)

                    // Crop quadrilateral outline
                    CropQuadPath(corners: corners.map(\.point))
                        .stroke(.white, lineWidth: 2)
                        .allowsHitTesting(false)

                    // Corner handles
                    ForEach(0..<4, id: \.self) { index in
                        cornerHandle(index: index, in: geometry.size)
                    }

                    // Magnifying loupe
                    if let active = activeCorner {
                        MagnifyingLoupe(
                            image: originalImage,
                            imageViewSize: rect.size,
                            pointInImageView: CGPoint(
                                x: corners[active].point.x - rect.minX,
                                y: corners[active].point.y - rect.minY
                            )
                        )
                        .position(
                            x: corners[active].point.x,
                            y: corners[active].point.y - 80
                        )
                        .allowsHitTesting(false)
                    }
                }
                .onAppear {
                    imageDisplayRect = rect
                    initializeCorners(in: rect)
                }
                .onChange(of: geometry.size) { _, newSize in
                    let newRect = aspectFitRect(for: originalImage.size, in: newSize)
                    imageDisplayRect = newRect
                    initializeCorners(in: newRect)
                }
            }
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

    // MARK: - Corner Handle

    @ViewBuilder
    private func cornerHandle(index: Int, in size: CGSize) -> some View {
        let handleSize: CGFloat = 44

        Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.3), radius: 4)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: handleSize, height: handleSize)
            .contentShape(Rectangle())
            .position(corners[index].point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        activeCorner = index
                        let clamped = CGPoint(
                            x: min(max(value.location.x, imageDisplayRect.minX), imageDisplayRect.maxX),
                            y: min(max(value.location.y, imageDisplayRect.minY), imageDisplayRect.maxY)
                        )
                        corners[index].point = clamped
                    }
                    .onEnded { _ in
                        activeCorner = nil
                    }
            )
    }

    // MARK: - Coordinate Conversion

    private func initializeCorners(in rect: CGRect) {
        if let detected = initialCorners {
            corners = [
                CornerPosition(id: 0, point: visionToDisplay(detected.topLeft, in: rect)),
                CornerPosition(id: 1, point: visionToDisplay(detected.topRight, in: rect)),
                CornerPosition(id: 2, point: visionToDisplay(detected.bottomRight, in: rect)),
                CornerPosition(id: 3, point: visionToDisplay(detected.bottomLeft, in: rect)),
            ]
        } else {
            // Default to image edges with margin
            let inset: CGFloat = 20
            corners = [
                CornerPosition(id: 0, point: CGPoint(x: rect.minX + inset, y: rect.minY + inset)),
                CornerPosition(id: 1, point: CGPoint(x: rect.maxX - inset, y: rect.minY + inset)),
                CornerPosition(id: 2, point: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)),
                CornerPosition(id: 3, point: CGPoint(x: rect.minX + inset, y: rect.maxY - inset)),
            ]
        }
    }

    private func resetCorners() {
        initializeCorners(in: imageDisplayRect)
    }

    private func applyCorners() {
        let rect = imageDisplayRect
        let detectedRect = DetectedRectangle(
            topLeft: displayToVision(corners[0].point, in: rect),
            topRight: displayToVision(corners[1].point, in: rect),
            bottomLeft: displayToVision(corners[3].point, in: rect),
            bottomRight: displayToVision(corners[2].point, in: rect),
            confidence: 1.0
        )
        coordinator.updateCorners(detectedRect)
    }

    // Vision coords: normalized 0..1, origin at bottom-left
    // Display coords: pixel position, origin at top-left
    private func visionToDisplay(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + (1 - normalized.y) * rect.height
        )
    }

    private func displayToVision(_ display: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: (display.x - rect.minX) / rect.width,
            y: 1 - (display.y - rect.minY) / rect.height
        )
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Supporting Types

private struct CornerPosition: Identifiable {
    let id: Int
    var point: CGPoint
}

// MARK: - Crop Overlay (dims area outside the quad)

private struct CropOverlay: Shape {
    let corners: [CGPoint]
    let bounds: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Full rect
        path.addRect(CGRect(origin: .zero, size: bounds))
        // Subtract quad
        if corners.count == 4 {
            var quad = Path()
            quad.move(to: corners[0])
            quad.addLine(to: corners[1])
            quad.addLine(to: corners[2])
            quad.addLine(to: corners[3])
            quad.closeSubpath()
            path.addPath(quad)
        }
        return path
    }
}

// MARK: - Crop Quad Outline

private struct CropQuadPath: Shape {
    let corners: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard corners.count == 4 else { return path }
        path.move(to: corners[0])
        path.addLine(to: corners[1])
        path.addLine(to: corners[2])
        path.addLine(to: corners[3])
        path.closeSubpath()
        return path
    }
}
