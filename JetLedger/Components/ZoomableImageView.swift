//
//  ZoomableImageView.swift
//  JetLedger
//

import SwiftUI
import UIKit

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100
        scrollView.addSubview(imageView)

        // Double-tap gesture
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = scrollView.viewWithTag(100) as? UIImageView else { return }

        // Reset zoom and update image when it changes
        if imageView.image !== image {
            scrollView.zoomScale = 1.0
            imageView.image = image
            imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        } else if imageView.frame.size != scrollView.bounds.size && scrollView.zoomScale == 1.0 {
            imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView = scrollView.viewWithTag(100) else { return }

            // Center the image when zoomed out
            let offsetX = max((scrollView.bounds.width - imageView.frame.width) / 2, 0)
            let offsetY = max((scrollView.bounds.height - imageView.frame.height) / 2, 0)
            imageView.center = CGPoint(
                x: imageView.frame.width / 2 + offsetX,
                y: imageView.frame.height / 2 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }

            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let location = gesture.location(in: scrollView.viewWithTag(100))
                let zoomRect = CGRect(
                    x: location.x - 75,
                    y: location.y - 75,
                    width: 150,
                    height: 150
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}
