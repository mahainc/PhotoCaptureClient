#if os(iOS)
    import PhotoCaptureClient
    import QuartzCore
    import UIKit
    import simd

    // MARK: - Detection Dot Overlay View

    /// Draws a single colored dot at the center of one fully-visible detected object (the largest
    /// on-screen box — a depth proxy where "bigger = nearer"). Used by the `.centerDot` overlay
    /// style in place of bounding boxes.
    ///
    /// The detection stream is a sequence of independent, noisy, identity-less snapshots (~3 fps,
    /// fresh per-frame boxes, no tracking), so a naked per-frame argmax makes the dot flip between
    /// near-equal objects and abandon the nearest object whenever its box briefly clips a frame
    /// edge. To stay stable this view tracks its current target across frames (by transform-invariant
    /// texture-space center) and:
    ///   - resists switching unless a different object is clearly larger (`switchAreaRatio`),
    ///   - holds — and keeps re-projecting — through brief drop-outs of the current target
    ///     (`holdDuration`), unless a comparably-large object is already on screen.
    /// New detections glide the dot; transform-only updates (pinch-zoom, layout) snap it so it tracks
    /// the geometry crisply, exactly like the bounding boxes and labels.
    final class DetectionDotOverlayView: UIView {

        private enum Style {
            static let diameter: CGFloat = 16
            static let borderWidth: CGFloat = 2
            static let moveDuration: TimeInterval = 0.28
            static let fadeDuration: TimeInterval = 0.2
        }

        private enum Tuning {
            /// A challenger object must be at least this much larger (by on-screen area) than the
            /// current target before the dot switches to it. Kills flip-flop between near-equal boxes.
            static let switchAreaRatio: Float = 1.25
            /// Max texture-space distance for a candidate to count as the *same* object as last frame
            /// (≈ one object's per-frame center drift; small enough not to grab a neighbouring object).
            static let sameObjectMaxDistance: Float = 0.08
            /// How long to keep the dot on its last target after it drops out of the candidate set
            /// (bridges brief edge-clips / confidence dips of the nearest object).
            static let holdDuration: CFTimeInterval = 0.5
        }

        /// What triggered a relayout — new detection data vs. a re-projection of the existing data.
        private enum RelayoutCause {
            case detections  // fresh detection results: glide + advance the hold clock
            case transform  // pinch-zoom / layout / activation: snap, don't touch the hold clock
        }

        /// A fully-visible detection considered for the dot, with both an identity key (texture-space
        /// center, transform-invariant) and on-screen geometry.
        private struct Candidate {
            let texCenter: SIMD2<Float>
            let screenArea: Float
            let screenPoint: CGPoint
            let color: SIMD4<Float>
        }

        private enum Decision {
            case show(Candidate, isSwitch: Bool)
            case hold
            case hide
        }

        /// Whether the dot is drawn at all. Toggled by `PhotoCaptureClient.setOverlayStyle`
        /// (`true` only for `.centerDot`).
        private var isActive: Bool = false
        /// Whether the dot is currently shown (used to decide fade-in vs. glide).
        private var wasShown: Bool = false

        // Cross-frame tracking state.
        private var lastTargetTexCenter: SIMD2<Float>?
        private var lastTargetArea: Float = 0
        private var lastSeenTime: CFTimeInterval = 0

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

        /// Replace the overlays and transform with fresh detection data, then reposition (glide).
        func update(
            overlays: [PhotoCaptureClient.OverlayRect],
            transform: OverlayTransform
        ) {
            self.overlays = overlays
            self.overlayTransform = transform
            relayout(cause: .detections)
        }

        /// Re-project under a new transform (aspect-fill / zoom changed) against the existing
        /// detections — snap, don't treat it as a new sighting.
        func update(transform: OverlayTransform) {
            self.overlayTransform = transform
            relayout(cause: .transform)
        }

        /// Enable or disable the dot style. Repositions (snap) without advancing the hold clock.
        func setActive(_ active: Bool) {
            isActive = active
            relayout(cause: .transform)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            relayout(cause: .transform)
        }

        private func relayout(cause: RelayoutCause) {
            let size = bounds.size
            guard isActive, size.width > 0, size.height > 0 else {
                hideDot()
                return
            }

            let candidates = makeCandidates(size: size)
            let now = CACurrentMediaTime()

            switch decideTarget(candidates: candidates, now: now) {
                case .show(let candidate, let isSwitch):
                    apply(candidate, isSwitch: isSwitch, cause: cause, now: now)
                case .hold:
                    holdInPlace(size: size)  // keep the dot glued to the held object, even under zoom
                case .hide:
                    hideDot()
            }
        }

        /// Map every fully-visible overlay to a `Candidate`, dropping degenerate (zero / non-finite
        /// area) boxes so the area-ratio hysteresis can't collapse to "always switch".
        private func makeCandidates(size: CGSize) -> [Candidate] {
            overlays.compactMap { overlay in
                guard
                    let rect = visibleScreenRect(
                        minX: overlay.x,
                        minY: overlay.y,
                        width: overlay.width,
                        height: overlay.height,
                        transform: overlayTransform
                    )
                else {
                    return nil
                }
                let screenArea = rect.width * rect.height
                guard screenArea.isFinite, screenArea > 0 else { return nil }
                let centerX = rect.minX + rect.width * 0.5
                let centerY = rect.minY + rect.height * 0.5
                return Candidate(
                    texCenter: SIMD2<Float>(
                        overlay.x + overlay.width * 0.5,
                        overlay.y + overlay.height * 0.5
                    ),
                    screenArea: screenArea,
                    screenPoint: CGPoint(
                        x: CGFloat(centerX) * size.width,
                        y: CGFloat(centerY) * size.height
                    ),
                    color: overlay.color
                )
            }
        }

        /// Decide what the dot should do this frame, applying stickiness and the hold grace window.
        private func decideTarget(
            candidates: [Candidate],
            now: CFTimeInterval
        ) -> Decision {
            guard let largest = candidates.max(by: { $0.screenArea < $1.screenArea }) else {
                // Nothing fully visible — hold briefly so a one-frame dropout doesn't blink the dot.
                return withinHold(now) ? .hold : .hide
            }
            guard let current = continuation(in: candidates) else {
                // Tracked object absent this frame. Only hold if it's worth waiting for — i.e. the
                // best available alternative is smaller than what we were tracking; otherwise take it.
                if withinHold(now), largest.screenArea < lastTargetArea {
                    return .hold
                }
                return .show(largest, isSwitch: true)
            }
            // Keep the current object unless a different one is clearly larger (nearer).
            let isClearlyLarger =
                largest.texCenter != current.texCenter
                && largest.screenArea >= current.screenArea * Tuning.switchAreaRatio
            if isClearlyLarger {
                return .show(largest, isSwitch: true)
            }
            return .show(current, isSwitch: false)
        }

        private func withinHold(_ now: CFTimeInterval) -> Bool {
            wasShown && now - lastSeenTime < Tuning.holdDuration
        }

        /// The candidate that is the continuation of the current target — the nearest one (by
        /// texture-space center) to last frame's target, within `sameObjectMaxDistance`.
        private func continuation(in candidates: [Candidate]) -> Candidate? {
            guard let last = lastTargetTexCenter else { return nil }
            var best: Candidate?
            var bestDistance = Tuning.sameObjectMaxDistance * Tuning.sameObjectMaxDistance
            for candidate in candidates {
                let deltaX = candidate.texCenter.x - last.x
                let deltaY = candidate.texCenter.y - last.y
                let distance = deltaX * deltaX + deltaY * deltaY
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
            return best
        }

        private func apply(
            _ candidate: Candidate,
            isSwitch: Bool,
            cause: RelayoutCause,
            now: CFTimeInterval
        ) {
            dot.backgroundColor = color(from: candidate.color)
            let point = candidate.screenPoint

            if !wasShown {
                // Appearing: place at the target and fade in (no slide from a stale position).
                dot.center = point
                wasShown = true
                UIView.animate(withDuration: Style.fadeDuration) { self.dot.alpha = 1 }
            } else if cause == .detections {
                // New detection moved/switched the target — glide.
                UIView.animate(
                    withDuration: Style.moveDuration,
                    delay: 0,
                    options: [.beginFromCurrentState, .curveEaseInOut]
                ) {
                    self.dot.center = point
                }
            } else {
                // Transform/layout re-projection — snap so the dot tracks pinch-zoom crisply.
                dot.center = point
            }

            lastTargetTexCenter = candidate.texCenter
            lastTargetArea = candidate.screenArea
            if cause == .detections {
                lastSeenTime = now
            }
        }

        /// Keep a held dot glued to its (currently off-candidate) object by re-projecting the last
        /// known texture-space center through the live transform, so a pinch-zoom during a hold still
        /// moves the dot instead of freezing it in screen pixels.
        private func holdInPlace(size: CGSize) {
            guard let texCenter = lastTargetTexCenter else { return }
            dot.center = projectedPoint(texCenter, size: size)
        }

        /// Project a texture-space point to view points through the aspect-fill + zoom transform —
        /// the same mapping as `visibleScreenRect`, but for a single point (no full-box visibility
        /// gate, since a held center may sit outside `[0, 1]`).
        private func projectedPoint(
            _ texCenter: SIMD2<Float>,
            size: CGSize
        ) -> CGPoint {
            let transform = overlayTransform
            let baseX = (texCenter.x - transform.uvOffset.x) / transform.uvScale.x
            let baseY = (texCenter.y - transform.uvOffset.y) / transform.uvScale.y
            let screenX = (baseX - transform.zoomAnchorX) * transform.zoomFactor + transform.zoomAnchorX
            let screenY = (baseY - transform.zoomAnchorY) * transform.zoomFactor + transform.zoomAnchorY
            return CGPoint(x: CGFloat(screenX) * size.width, y: CGFloat(screenY) * size.height)
        }

        private func hideDot() {
            lastTargetTexCenter = nil
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
