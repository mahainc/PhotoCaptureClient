#if os(iOS)
    import PhotoCaptureClient
    import UIKit
    import simd

    // MARK: - Overlay Transform

    /// Snapshot of the aspect-fill + visual-zoom transform needed to place overlays on screen.
    /// Mirrors the values the Metal pass reads from `aspectFillUniforms` and `_visualZoom`.
    struct OverlayTransform: Equatable {
        var uvScale: SIMD2<Float> = SIMD2<Float>(1, 1)
        var uvOffset: SIMD2<Float> = SIMD2<Float>(0, 0)
        var zoomFactor: Float = 1.0
        var zoomAnchorX: Float = 0.5
        var zoomAnchorY: Float = 0.5
    }

    /// A box in screen-normalized space (0..1, top-left origin).
    struct ScreenRect: Equatable {
        let minX: Float
        let minY: Float
        let width: Float
        let height: Float
    }

    /// Maps a normalized texture-space box to screen-normalized (0..1, top-left) space, applying
    /// the aspect-fill crop then the visual zoom — the exact inverse the camera shader applies.
    ///
    /// Returns `nil` when the box is **not fully inside** the visible preview (any edge crosses
    /// `[0, 1]`). Shared by the Metal box pass and the label overlay so that a box and its label
    /// are hidden together the moment the detection drifts off the visible frame.
    func visibleScreenRect(
        minX: Float,
        minY: Float,
        width: Float,
        height: Float,
        transform: OverlayTransform
    ) -> ScreenRect? {
        // Undo aspect-fill crop: screenUV = (texUV - uvOffset) / uvScale
        let baseX = (minX - transform.uvOffset.x) / transform.uvScale.x
        let baseY = (minY - transform.uvOffset.y) / transform.uvScale.y
        let baseW = width / transform.uvScale.x
        let baseH = height / transform.uvScale.y
        // Apply zoom (inverse of shader division → multiply about the anchor).
        let screenX = (baseX - transform.zoomAnchorX) * transform.zoomFactor + transform.zoomAnchorX
        let screenY = (baseY - transform.zoomAnchorY) * transform.zoomFactor + transform.zoomAnchorY
        let screenW = baseW * transform.zoomFactor
        let screenH = baseH * transform.zoomFactor
        // Full-frame test: only fully-visible boxes survive.
        guard screenX >= 0, screenY >= 0, screenX + screenW <= 1.0, screenY + screenH <= 1.0 else {
            return nil
        }
        return ScreenRect(minX: screenX, minY: screenY, width: screenW, height: screenH)
    }

    // MARK: - Detection Label Overlay View

    /// Draws detection labels (class name + confidence) as pooled `UILabel`s above the Metal
    /// preview. Repositioned whenever the overlays, the transform (aspect-fill / zoom), or the
    /// view bounds change. Visibility is toggled via `labelsVisible`.
    final class DetectionLabelOverlayView: UIView {

        private enum Style {
            static let fontSize: CGFloat = 13
            static let horizontalPadding: CGFloat = 6
            static let verticalPadding: CGFloat = 3
            static let cornerRadius: CGFloat = 4
            static let backgroundAlpha: CGFloat = 0.7
            /// Gap between the label and the top edge of its box.
            static let gap: CGFloat = 2
        }

        /// Whether labels are drawn. Toggled by `PhotoCaptureClient.setLabelsVisible`.
        var labelsVisible: Bool = true {
            didSet { relayout() }
        }

        private var overlays: [PhotoCaptureClient.OverlayRect] = []
        private var overlayTransform = OverlayTransform()
        private var labelPool: [UILabel] = []

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Replace the overlays and transform, then reposition. Call on the main thread.
        func update(
            overlays: [PhotoCaptureClient.OverlayRect],
            transform: OverlayTransform
        ) {
            self.overlays = overlays
            self.overlayTransform = transform
            relayout()
        }

        /// Update only the transform (aspect-fill / zoom changed), then reposition. Main thread.
        func update(transform: OverlayTransform) {
            self.overlayTransform = transform
            relayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            relayout()
        }

        private func relayout() {
            let size = bounds.size
            guard labelsVisible, size.width > 0, size.height > 0 else {
                labelPool.forEach { $0.isHidden = true }
                return
            }

            var used = 0
            for overlay in overlays {
                guard let text = labelText(for: overlay), !text.isEmpty else {
                    continue
                }
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

                let label = label(at: used)
                used += 1
                label.text = text
                label.backgroundColor = backgroundColor(for: overlay.color)

                let textSize = label.intrinsicContentSize
                let labelWidth = ceil(textSize.width) + Style.horizontalPadding * 2
                let labelHeight = ceil(textSize.height) + Style.verticalPadding * 2

                // Box top-left corner in view points.
                let boxLeft = CGFloat(rect.minX) * size.width
                let boxTop = CGFloat(rect.minY) * size.height

                // Prefer placing the label just above the box; fall back to inside-top if no room.
                var originX = boxLeft
                var originY = boxTop - labelHeight - Style.gap
                if originY < 0 {
                    originY = boxTop + Style.gap
                }
                originX = min(max(0, originX), max(0, size.width - labelWidth))
                originY = min(max(0, originY), max(0, size.height - labelHeight))

                label.frame = CGRect(x: originX, y: originY, width: labelWidth, height: labelHeight)
                label.isHidden = false
            }

            // Hide any pooled labels not used this pass.
            if used < labelPool.count {
                for index in used..<labelPool.count {
                    labelPool[index].isHidden = true
                }
            }
        }

        private func label(at index: Int) -> UILabel {
            if index < labelPool.count {
                return labelPool[index]
            }
            let label = UILabel()
            label.font = .systemFont(ofSize: Style.fontSize, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.layer.cornerRadius = Style.cornerRadius
            label.layer.masksToBounds = true
            addSubview(label)
            labelPool.append(label)
            return label
        }

        private func labelText(for overlay: PhotoCaptureClient.OverlayRect) -> String? {
            guard let label = overlay.label, !label.isEmpty else {
                return nil
            }
            guard let confidence = overlay.confidence else {
                return label
            }
            return "\(label) \(Int((confidence * 100).rounded()))%"
        }

        private func backgroundColor(for color: SIMD4<Float>) -> UIColor {
            UIColor(
                red: CGFloat(color.x),
                green: CGFloat(color.y),
                blue: CGFloat(color.z),
                alpha: Style.backgroundAlpha
            )
        }
    }
#endif
