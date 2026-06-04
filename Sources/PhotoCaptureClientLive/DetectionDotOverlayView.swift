#if os(iOS)
    import PhotoCaptureClient
    import UIKit
    import simd

    // MARK: - Detection Dot Overlay View

    /// Draws a single colored dot at the center of the fully-visible detected object nearest the
    /// screen center. Used by the `.centerDot` overlay style in place of bounding boxes. The dot
    /// animates ("glides") from one object's center to another as the camera is reframed, and
    /// fades in/out as a target appears/disappears. Kept in sync with the same aspect-fill + zoom
    /// transform the boxes use, so it tracks pinch-zoom too.
    final class DetectionDotOverlayView: UIView {

        private enum Style {
            static let diameter: CGFloat = 16
            static let borderWidth: CGFloat = 2
            static let moveDuration: TimeInterval = 0.28
            static let fadeDuration: TimeInterval = 0.2
        }

        /// Whether the dot is drawn at all. Toggled by `PhotoCaptureClient.setOverlayStyle`
        /// (`true` only for `.centerDot`).
        private var isActive: Bool = false
        /// Whether the dot is currently shown (used to decide fade-in vs. glide).
        private var wasShown: Bool = false

        private var overlays: [PhotoCaptureClient.OverlayRect] = []
        private var overlayTransform = OverlayTransform()

        private let dot: UIView = {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: Style.diameter, height: Style.diameter))
            view.layer.cornerRadius = Style.diameter / 2
            view.layer.borderWidth = Style.borderWidth
            view.layer.borderColor = UIColor.white.cgColor
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.4
            view.layer.shadowRadius = 3
            view.layer.shadowOffset = .zero
            view.isUserInteractionEnabled = false
            view.alpha = 0
            return view
        }()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            addSubview(dot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Replace the overlays and transform, then reposition (animated). Call on the main thread.
        func update(
            overlays: [PhotoCaptureClient.OverlayRect],
            transform: OverlayTransform
        ) {
            self.overlays = overlays
            self.overlayTransform = transform
            relayout(animated: true)
        }

        /// Update only the transform (aspect-fill / zoom changed), then reposition. Main thread.
        func update(transform: OverlayTransform) {
            self.overlayTransform = transform
            relayout(animated: true)
        }

        /// Enable or disable the dot style. Repositions without animation.
        func setActive(_ active: Bool) {
            isActive = active
            relayout(animated: false)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            relayout(animated: false)
        }

        private func relayout(animated: Bool) {
            let size = bounds.size
            guard isActive, size.width > 0, size.height > 0 else {
                hideDot()
                return
            }

            // Pick the fully-visible detection with the largest on-screen box area — a depth
            // proxy where "bigger box = nearer object".
            var bestPoint: CGPoint?
            var bestColor: SIMD4<Float> = SIMD4<Float>(0, 1, 0, 1)
            var bestArea: Float = 0
            for overlay in overlays {
                guard
                    let rect = visibleScreenRect(
                        minX: overlay.x,
                        minY: overlay.y,
                        width: overlay.width,
                        height: overlay.height,
                        transform: overlayTransform
                    )
                else {
                    continue
                }
                let area = rect.width * rect.height
                if area > bestArea {
                    bestArea = area
                    bestColor = overlay.color
                    let centerX = rect.minX + rect.width * 0.5
                    let centerY = rect.minY + rect.height * 0.5
                    bestPoint = CGPoint(
                        x: CGFloat(centerX) * size.width,
                        y: CGFloat(centerY) * size.height
                    )
                }
            }

            guard let point = bestPoint else {
                hideDot()
                return
            }

            dot.backgroundColor = color(from: bestColor)

            if !wasShown {
                // Appearing: place at the target and fade in (no slide from a stale position).
                dot.center = point
                wasShown = true
                UIView.animate(withDuration: Style.fadeDuration) { self.dot.alpha = 1 }
            } else if animated {
                // Glide from the previous center to the new one.
                UIView.animate(
                    withDuration: Style.moveDuration,
                    delay: 0,
                    options: [.beginFromCurrentState, .curveEaseInOut]
                ) {
                    self.dot.center = point
                }
            } else {
                dot.center = point
            }
        }

        private func hideDot() {
            guard wasShown else {
                dot.alpha = 0
                return
            }
            wasShown = false
            UIView.animate(withDuration: Style.fadeDuration) { self.dot.alpha = 0 }
        }

        private func color(from rgba: SIMD4<Float>) -> UIColor {
            UIColor(
                red: CGFloat(rgba.x),
                green: CGFloat(rgba.y),
                blue: CGFloat(rgba.z),
                alpha: CGFloat(rgba.w)
            )
        }
    }
#endif
