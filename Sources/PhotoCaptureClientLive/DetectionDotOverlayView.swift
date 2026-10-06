#if os(iOS)
    import PhotoCaptureClient
    import QuartzCore
    import UIKit
    import simd

    // MARK: - Detection Dot Overlay View

    /// Draws a single colored dot at the center of the fully-visible detected object the user is
    /// *aiming at* — ranked center-first: the object nearest the frame center wins, and true Z depth
    /// (LiDAR / dual camera) only decides between objects that are comparably centered, picking the
    /// nearer one. Used by the `.centerDot` overlay style in place of bounding boxes.
    ///
    /// Detections carry a stable per-object track ID (from the upstream multi-object tracker), so the
    /// view ID-locks onto its current target and follows that identity across frames — falling back to
    /// the transform-invariant texture-space center when no ID is present (untracked / depth-less). It:
    ///   - resists switching unless a *different* object is clearly nearer (`switchDepthFraction` /
    ///     `switchProximityFraction`),
    ///   - holds — and keeps re-projecting — through brief drop-outs of the current target
    ///     (`holdDuration`), unless a nearer object is already on screen,
    ///   - smooths same-object motion with a 1€ filter (the tracker already damps box jitter upstream).
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
            /// A challenger must be nearer than the current target by at least this *fraction* of the
            /// current depth before the dot switches to it (relative, so it scales with range). Kills
            /// flip-flop between objects at near-equal distance. Tuned high for confident commitment.
            static let switchDepthFraction: Float = 0.30
            /// Absolute depth floor (metres) for the switch margin, so very near objects don't chatter
            /// when the relative margin shrinks to noise.
            static let switchDepthFloor: Float = 0.03
            /// A challenger must be this fraction closer to the frame center than the current target
            /// before the dot switches to it. Tuned high for confident commitment.
            static let switchProximityFraction: Float = 0.30
            /// Absolute center-proximity floor for the switch margin, so an already-centered target
            /// doesn't chatter when the relative margin shrinks to noise.
            static let switchProximityFloor: Float = 0.05
            /// How close in center-proximity two objects must be to count as "both centered", where
            /// depth — not position — decides between them. Center is the primary signal: the user
            /// aims at what they mean, so a nearer object only wins when it is just as centered.
            static let centreTieBand: Float = 0.08
            /// Fraction of the frame a box may cover before it starts reading as backdrop rather than
            /// subject. A box that fills the frame has its center at the frame center for free, which
            /// let a far, frame-filling object win center-first outright; coverage past this cap is
            /// penalised so it no longer does.
            static let coverageSoftCap: Float = 0.6
            /// Center-proximity added per unit of coverage beyond `coverageSoftCap`. Tuned so a
            /// full-frame box (coverage ≈ 1) gains ≈ 0.2 — well past `centreTieBand` — dropping it out
            /// of "both centered" so a smaller, genuinely nearer object takes the dot.
            static let coveragePenaltyWeight: Float = 0.5
            /// Two objects count as "equally near" when their depth keys differ by less than this
            /// (metres); detector confidence then decides between them.
            static let depthTieBand: Float = 0.3
            /// When two objects are both centred and equally near, a challenger needs at least this
            /// much more confidence (0–1) before it takes the dot.
            static let confidenceTieDelta: Float = 0.1
            /// Metres added beyond the farthest valid depth in a frame to rank objects whose depth
            /// couldn't be sampled — they fall behind any object with a real reading, but stay ordered
            /// among themselves by center-proximity.
            static let depthlessPenalty: Float = 0.5
            /// Max texture-space distance for a candidate to count as the *same* object as last frame
            /// (≈ one object's per-frame center drift; small enough not to grab a neighbouring object).
            static let sameObjectMaxDistance: Float = 0.08
            /// How long to keep the dot on its last target after it drops out of the candidate set
            /// (bridges brief edge-clips / confidence dips of the nearest object).
            ///
            /// One second, not half: detections arrive at roughly 3fps, so half a second
            /// bridged a single missed frame and a two-frame gap blinked the dot. The
            /// tracker already coasts a track for `maxAge` frames — about a second at this
            /// cadence — so this now outlasts exactly what the tracker is willing to
            /// forgive, instead of hiding a dot the tracker still believes in.
            static let holdDuration: CFTimeInterval = 1.0
            /// How long a candidate must have been tracked before it may take the dot away
            /// from the object it is already on.
            ///
            /// The detector emits short-lived false positives — two or three frames of a
            /// "laptop" that is not there — and some land nearer the camera than the real
            /// subject. Without this each one satisfied the depth margin, took the dot,
            /// vanished, and handed it back: measured on a still camera, the dot appeared
            /// to drop and re-acquire the same object while nothing had moved.
            ///
            /// It gates *stealing* only. A candidate of any age may take an empty dot, so
            /// first acquisition stays immediate.
            static let minimumAgeToSteal: TimeInterval = 0.8
            /// 1€ filter for same-object pointer smoothing: a low cutoff kills jitter when still, β
            /// raises the cutoff with speed to cut lag. Conservative — the tracker's Kalman already
            /// damps box jitter, so this only removes residual high-frequency noise.
            static let smoothingMinCutoff: Float = 2.0
            static let smoothingBeta: Float = 0.4
        }

        /// What triggered a relayout — new detection data vs. a re-projection of the existing data.
        private enum RelayoutCause {
            case detections  // fresh detection results: glide + advance the hold clock
            case transform  // pinch-zoom / layout / activation: snap, don't touch the hold clock
        }

        /// A fully-visible detection considered for the dot, with both an identity key (texture-space
        /// center, transform-invariant) and on-screen geometry.
        private struct Candidate {
            /// Stable identity from the upstream tracker (`nil` when untracked).
            let trackID: UUID?
            let texCenter: SIMD2<Float>
            /// Normalized (0-1) screen-space center, post aspect-fill + zoom.
            let screenCenter: SIMD2<Float>
            let screenPoint: CGPoint
            let color: SIMD4<Float>
            /// Metric depth in metres (smaller = nearer); `nil` when depth couldn't be sampled.
            let depth: Float?
            /// How long the upstream tracker has held this object, in seconds.
            let trackedSeconds: TimeInterval
            /// Normalized screen-space distance from the frame center (0 = centered, ≈0.7 at a corner).
            let proximity: Float
            /// Fraction of the frame the fully-visible box covers (0–1, 1 = fills the frame). Feeds the
            /// coverage penalty that stops a frame-filling box from reading as perfectly centered.
            let coverage: Float
            /// Detector confidence (0–1); `nil` when the overlay carries none. Breaks ties between
            /// objects that are both centred and equally near.
            let confidence: Float?
        }

        private enum Decision {
            case show(Candidate, isSwitch: Bool)
            case hold
            case hide
        }

        /// A 1€ low-pass filter (Casiez et al., CHI 2012): an adaptive cutoff trades jitter for lag —
        /// low cutoff (steady) kills jitter, higher cutoff (fast) cuts lag.
        private struct OneEuroFilter {
            let minCutoff: Float
            let beta: Float
            var derivativeCutoff: Float = 1
            private var hasPrevious = false
            private var previousValue: Float = 0
            private var previousDerivative: Float = 0
            private var previousTime: CFTimeInterval = 0

            init(
                minCutoff: Float,
                beta: Float
            ) {
                self.minCutoff = minCutoff
                self.beta = beta
            }

            mutating func reset(
                to value: Float,
                at time: CFTimeInterval
            ) {
                hasPrevious = true
                previousValue = value
                previousDerivative = 0
                previousTime = time
            }

            mutating func filter(
                _ value: Float,
                at time: CFTimeInterval
            ) -> Float {
                guard hasPrevious else {
                    reset(to: value, at: time)
                    return value
                }
                let elapsed = Float(max(time - previousTime, 1e-4))
                previousTime = time
                let derivative = (value - previousValue) / elapsed
                let derivativeAlpha = Self.alpha(cutoff: derivativeCutoff, deltaTime: elapsed)
                let smoothedDerivative =
                    derivativeAlpha * derivative + (1 - derivativeAlpha) * previousDerivative
                previousDerivative = smoothedDerivative
                let cutoff = minCutoff + beta * abs(smoothedDerivative)
                let valueAlpha = Self.alpha(cutoff: cutoff, deltaTime: elapsed)
                let smoothed = valueAlpha * value + (1 - valueAlpha) * previousValue
                previousValue = smoothed
                return smoothed
            }

            private static func alpha(
                cutoff: Float,
                deltaTime: Float
            ) -> Float {
                let tau = 1 / (2 * Float.pi * cutoff)
                return 1 / (1 + tau / deltaTime)
            }
        }

        /// Whether the dot is drawn at all. Toggled by `PhotoCaptureClient.setOverlayStyle`
        /// (`true` only for `.centerDot`).
        private var isActive: Bool = false
        /// Whether the dot is currently shown (used to decide fade-in vs. glide).
        private var wasShown: Bool = false

        // Cross-frame tracking state.
        /// The tracked target's stable track ID — the primary identity key (when present).
        private var lastTargetTrackID: UUID?
        private var lastTargetTexCenter: SIMD2<Float>?
        /// The tracked target's last sampled depth (metres); `nil` if it had no depth.
        private var lastTargetDepth: Float?
        /// The tracked target's last screen-space center-proximity.
        private var lastTargetProximity: Float = 0
        private var lastSeenTime: CFTimeInterval = 0

        // Per-axis 1€ smoothing of the selected object's center (same-object motion only).
        private var smootherX = OneEuroFilter(
            minCutoff: Tuning.smoothingMinCutoff,
            beta: Tuning.smoothingBeta
        )
        private var smootherY = OneEuroFilter(
            minCutoff: Tuning.smoothingMinCutoff,
            beta: Tuning.smoothingBeta
        )

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
                    apply(candidate, isSwitch: isSwitch, cause: cause, now: now, size: size)
                case .hold:
                    holdInPlace(size: size)  // keep the dot glued to the held object, even under zoom
                case .hide:
                    hideDot()
            }
        }

        /// Map every overlay that overlaps the frame to a `Candidate`, using its visible (clipped)
        /// rect so a large object the user has centred still qualifies, and dropping degenerate (zero
        /// / non-finite area) boxes so the area-ratio hysteresis can't collapse to "always switch".
        private func makeCandidates(size: CGSize) -> [Candidate] {
            overlays.compactMap { overlay in
                guard let rect = clippedScreenRect(for: overlay, transform: overlayTransform) else {
                    return nil
                }
                let screenArea = rect.width * rect.height
                guard screenArea.isFinite, screenArea > 0 else { return nil }
                let centerX = rect.minX + rect.width * 0.5
                let centerY = rect.minY + rect.height * 0.5
                let proximityX = centerX - 0.5
                let proximityY = centerY - 0.5
                return Candidate(
                    trackID: overlay.trackID,
                    texCenter: SIMD2<Float>(
                        overlay.x + overlay.width * 0.5,
                        overlay.y + overlay.height * 0.5
                    ),
                    screenCenter: SIMD2<Float>(centerX, centerY),
                    screenPoint: CGPoint(
                        x: CGFloat(centerX) * size.width,
                        y: CGFloat(centerY) * size.height
                    ),
                    color: overlay.color,
                    depth: overlay.depth,
                    trackedSeconds: overlay.trackedSeconds,
                    proximity: (proximityX * proximityX + proximityY * proximityY).squareRoot(),
                    coverage: screenArea,
                    confidence: overlay.confidence
                )
            }
        }

        /// Center-proximity adjusted so a frame-filling box no longer reads as perfectly centered:
        /// coverage beyond `coverageSoftCap` is penalised, so a far object that merely fills the frame
        /// ranks behind a smaller object genuinely near the center. This is the key the center-first
        /// ranking compares, in place of raw `proximity`.
        private func aimProximity(_ candidate: Candidate) -> Float {
            let excessCoverage = max(0, candidate.coverage - Tuning.coverageSoftCap)
            return candidate.proximity + excessCoverage * Tuning.coveragePenaltyWeight
        }

        /// Decide what the dot should do this frame, ranking center-first — the object nearest the
        /// frame center wins, and depth only separates objects that are comparably centered — then
        /// applying stickiness + the hold grace window.
        private func decideTarget(
            candidates: [Candidate],
            now: CFTimeInterval
        ) -> Decision {
            // Depth tiebreaker scalar: metric depth when available; otherwise a penalty placed just
            // beyond the farthest real reading so depth-less candidates rank behind any real one but
            // stay ordered among themselves. Consulted only between objects that are comparably
            // centered — center-proximity is the primary key.
            let penaltyBase = candidates.compactMap(\.depth).max()
            func depthKey(_ candidate: Candidate) -> Float {
                if let depth = candidate.depth { return depth }
                if let base = penaltyBase { return base + Tuning.depthlessPenalty }
                return 0
            }
            // Center-first: the object nearer the frame center wins outright; depth decides only
            // between objects within `centreTieBand` of each other ("both centered").
            func isBetter(
                _ lhs: Candidate,
                _ rhs: Candidate
            ) -> Bool {
                let lhsAim = aimProximity(lhs)
                let rhsAim = aimProximity(rhs)
                if abs(lhsAim - rhsAim) > Tuning.centreTieBand {
                    return lhsAim < rhsAim
                }
                let lhsDepth = depthKey(lhs)
                let rhsDepth = depthKey(rhs)
                if abs(lhsDepth - rhsDepth) > Tuning.depthTieBand {
                    return lhsDepth < rhsDepth
                }
                return (lhs.confidence ?? 0) > (rhs.confidence ?? 0)
            }
            // Whether `challenger` *clearly* beats `incumbent`: clearly more centered, or — when the
            // two are comparably centered — clearly nearer in depth.
            func isClearlyBetter(
                _ challenger: Candidate,
                than incumbent: Candidate
            ) -> Bool {
                let incumbentAim = aimProximity(incumbent)
                let proximityGap = incumbentAim - aimProximity(challenger)
                let proximityThreshold = max(
                    Tuning.switchProximityFloor,
                    incumbentAim * Tuning.switchProximityFraction
                )
                if proximityGap >= proximityThreshold { return true }
                if abs(proximityGap) <= Tuning.centreTieBand {
                    let depthGap = depthKey(incumbent) - depthKey(challenger)
                    let depthThreshold = max(
                        Tuning.switchDepthFloor,
                        depthKey(incumbent) * Tuning.switchDepthFraction
                    )
                    if depthGap >= depthThreshold { return true }
                    if abs(depthGap) <= Tuning.depthTieBand {
                        return (challenger.confidence ?? 0) - (incumbent.confidence ?? 0)
                            >= Tuning.confidenceTieDelta
                    }
                }
                return false
            }

            // `min(by:)` is nil only when nothing is fully visible — hold briefly so a one-frame
            // dropout doesn't blink the dot.
            guard let best = candidates.min(by: isBetter) else {
                return withinHold(now) ? .hold : .hide
            }

            guard let current = continuation(in: candidates) else {
                // Tracked object absent this frame. Hold only if it's worth waiting for — i.e. the
                // best available alternative is less centered (or comparably centered but farther)
                // than what we were tracking. Raw proximity (not aimProximity) is deliberate on this
                // brief hold-grace path: `best` is already the coverage-penalised winner from
                // `isBetter`, and this only decides whether to wait out a one-frame dropout.
                let lastDepthKey =
                    lastTargetDepth ?? (penaltyBase.map { $0 + Tuning.depthlessPenalty } ?? 0)
                let bestDepthKey = depthKey(best)
                let trackedWasBetter =
                    best.proximity > lastTargetProximity + Tuning.centreTieBand
                    || (abs(best.proximity - lastTargetProximity) <= Tuning.centreTieBand
                        && bestDepthKey > lastDepthKey)
                if withinHold(now), trackedWasBetter {
                    return .hold
                }
                return .show(best, isSwitch: true)
            }

            // Keep the current object unless a *different* one is clearly nearer.
            let isDifferentObject: Bool
            if let bestID = best.trackID, let currentID = current.trackID {
                isDifferentObject = bestID != currentID
            } else {
                isDifferentObject = best.texCenter != current.texCenter
            }
            // A candidate the tracker has barely met does not get to take the dot, however
            // near it measures: most of those are false positives that will be gone in two
            // frames, and handing them the dot is what made it flicker.
            let isOldEnoughToSteal = best.trackedSeconds >= Tuning.minimumAgeToSteal
            if isDifferentObject, isOldEnoughToSteal, isClearlyBetter(best, than: current) {
                return .show(best, isSwitch: true)
            }
            return .show(current, isSwitch: false)
        }

        private func withinHold(_ now: CFTimeInterval) -> Bool {
            wasShown && now - lastSeenTime < Tuning.holdDuration
        }

        /// The candidate that is the continuation of the current target — the nearest one (by
        /// texture-space center) to last frame's target, within `sameObjectMaxDistance`.
        private func continuation(in candidates: [Candidate]) -> Candidate? {
            // Prefer an exact track-ID match: the tracker gives a stable identity, so this follows the
            // same object even across large per-frame jumps and never grabs a neighbour. If the tracked
            // ID is absent this frame, return nil so the hold / drop-out logic takes over.
            if let lastID = lastTargetTrackID {
                return candidates.first { $0.trackID == lastID }
            }
            // No track ID (untracked / depth-less path) — fall back to nearest texture-space center.
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
            now: CFTimeInterval,
            size: CGSize
        ) {
            dot.backgroundColor = color(from: candidate.color)
            let rawPoint = candidate.screenPoint

            if !wasShown {
                // Appearing: place at the target and fade in (no slide from a stale position).
                resetSmoother(to: candidate.screenCenter, at: now)
                dot.center = rawPoint
                wasShown = true
                UIView.animate(withDuration: Style.fadeDuration) { self.dot.alpha = 1 }
            } else if cause == .detections {
                if isSwitch {
                    // Switched to a different object — reset the smoother and glide cleanly to it.
                    resetSmoother(to: candidate.screenCenter, at: now)
                    UIView.animate(
                        withDuration: Style.moveDuration,
                        delay: 0,
                        options: [.beginFromCurrentState, .curveEaseInOut]
                    ) {
                        self.dot.center = rawPoint
                    }
                } else {
                    // Same object — damp residual jitter with the 1€ filter, then glide.
                    let point = smoothedPoint(candidate.screenCenter, at: now, size: size)
                    UIView.animate(
                        withDuration: Style.moveDuration,
                        delay: 0,
                        options: [.beginFromCurrentState, .curveEaseInOut]
                    ) {
                        self.dot.center = point
                    }
                }
            } else {
                // Transform/layout re-projection — snap so the dot tracks pinch-zoom crisply.
                resetSmoother(to: candidate.screenCenter, at: now)
                dot.center = rawPoint
            }

            lastTargetTexCenter = candidate.texCenter
            lastTargetTrackID = candidate.trackID
            lastTargetDepth = candidate.depth
            lastTargetProximity = candidate.proximity
            if cause == .detections {
                lastSeenTime = now
            }
        }

        private func resetSmoother(
            to center: SIMD2<Float>,
            at time: CFTimeInterval
        ) {
            smootherX.reset(to: center.x, at: time)
            smootherY.reset(to: center.y, at: time)
        }

        private func smoothedPoint(
            _ center: SIMD2<Float>,
            at time: CFTimeInterval,
            size: CGSize
        ) -> CGPoint {
            let smoothedX = smootherX.filter(center.x, at: time)
            let smoothedY = smootherY.filter(center.y, at: time)
            return CGPoint(x: CGFloat(smoothedX) * size.width, y: CGFloat(smoothedY) * size.height)
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
            // A point is a zero-size box, so it shares `screenRect`'s aspect-fill + zoom mapping.
            let rect = screenRect(
                minX: texCenter.x,
                minY: texCenter.y,
                width: 0,
                height: 0,
                transform: overlayTransform
            )
            return CGPoint(x: CGFloat(rect.minX) * size.width, y: CGFloat(rect.minY) * size.height)
        }

        private func hideDot() {
            lastTargetTexCenter = nil
            lastTargetTrackID = nil
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
