//
//  MagnifyingLoupe.swift
//  JetLedger
//

import SwiftUI

struct MagnifyingLoupe: View {
    let image: UIImage
    let imageViewSize: CGSize
    let pointInImageView: CGPoint

    private let loupeSize: CGFloat = 120
    private let zoomScale: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            // Guard against zero dimensions that would produce NaN through division
            guard imageViewSize.width > 0, imageViewSize.height > 0,
                  image.size.width > 0, image.size.height > 0 else { return }

            // Calculate the portion of the image to show
            let imageScaleX = image.size.width / imageViewSize.width
            let imageScaleY = image.size.height / imageViewSize.height

            let imagePt = CGPoint(
                x: pointInImageView.x * imageScaleX,
                y: pointInImageView.y * imageScaleY
            )

            // The region in the original image we want to display
            let regionSize = CGSize(
                width: (loupeSize / zoomScale) * imageScaleX,
                height: (loupeSize / zoomScale) * imageScaleY
            )
            let regionOrigin = CGPoint(
                x: imagePt.x - regionSize.width / 2,
                y: imagePt.y - regionSize.height / 2
            )

            // Draw scaled image portion
            let resolvedImage = context.resolve(Image(uiImage: image))
            let drawScale = loupeSize / (regionSize.width / imageScaleX)
            let drawOrigin = CGPoint(
                x: -regionOrigin.x / imageScaleX * drawScale,
                y: -regionOrigin.y / imageScaleY * drawScale
            )
            let drawSize = CGSize(
                width: image.size.width / imageScaleX * drawScale,
                height: image.size.height / imageScaleY * drawScale
            )

            context.clipToLayer { clipCtx in
                let circlePath = Circle().path(in: CGRect(origin: .zero, size: size))
                clipCtx.fill(circlePath, with: .color(.white))
            }

            context.drawLayer { layerCtx in
                layerCtx.draw(
                    resolvedImage,
                    in: CGRect(origin: drawOrigin, size: drawSize)
                )
            }

            // Crosshair
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let crossSize: CGFloat = 16
            var crossPath = Path()
            crossPath.move(to: CGPoint(x: center.x - crossSize / 2, y: center.y))
            crossPath.addLine(to: CGPoint(x: center.x + crossSize / 2, y: center.y))
            crossPath.move(to: CGPoint(x: center.x, y: center.y - crossSize / 2))
            crossPath.addLine(to: CGPoint(x: center.x, y: center.y + crossSize / 2))
            context.stroke(crossPath, with: .color(.red.opacity(0.8)), lineWidth: 1)

            // Border
            let borderPath = Circle().path(in: CGRect(origin: .zero, size: size))
            context.stroke(borderPath, with: .color(.white), lineWidth: 3)
        }
        .frame(width: loupeSize, height: loupeSize)
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}
