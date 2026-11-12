#if os(iOS)
    import PhotoCaptureClient
    import QuartzCore
    import UIKit
    import simd

    // MARK: - Detection Dot Overlay View — Animation & Geometry

    /// Positioning, animation and texture-space projection for the dot. The ranking / decision logic
    /// (which object the dot should be on) lives in `DetectionDotOverlayView`; this extension owns how
    /// the dot *moves* once a target is chosen: fade-in, same-object glide (1€-smoothed), switch glide,
    /// transform snap, hold re-projection, and fade-out.
    extension DetectionDotOverlayView {

        func apply(
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
        func holdInPlace(size: CGSize) {
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

        func hideDot() {
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
