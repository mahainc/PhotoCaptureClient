#if canImport(Vision)
    import CoreVideo
    import Vision
    import simd

    // MARK: - CameraMotionEstimator

    /// Estimates the global previous→current camera motion from two frames using Vision's image
    /// registration (no OpenCV), producing a `CameraMotion` the tracker uses for BoT-SORT CMC. The only
    /// Vision-dependent type in this module; everything else is pure math.
    ///
    /// Resolution-independent: translations are normalized by image size, so frames may be downscaled
    /// before estimation for speed without changing the result.
    public struct CameraMotionEstimator: Sendable {
        public let mode: CameraMotionMode

        public init(mode: CameraMotionMode) {
            self.mode = mode
        }

        /// Returns the motion that maps a point in `previous` to where it appears in `current`, in
        /// normalized top-left space. Returns `.identity` on `.off`, registration failure, or an
        /// implausibly large result.
        public func estimate(
            previous: CVPixelBuffer,
            current: CVPixelBuffer
        ) -> CameraMotion {
            guard mode != .off else { return .identity }
            let width = CVPixelBufferGetWidth(current)
            let height = CVPixelBufferGetHeight(current)
            guard width > 0, height > 0 else { return .identity }

            switch mode {
                case .off:
                    return .identity
                case .translational:
                    return estimateTranslation(
                        previous: previous,
                        current: current,
                        width: width,
                        height: height
                    )
                case .homographic:
                    return estimateHomography(previous: previous, current: current)
            }
        }

        // The request is *targeted* at `previous` and performed on `current`, so the resulting transform
        // aligns previous → current — exactly the direction we warp predictions by.
        private func estimateTranslation(
            previous: CVPixelBuffer,
            current: CVPixelBuffer,
            width: Int,
            height: Int
        ) -> CameraMotion {
            let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: previous)
            let handler = VNImageRequestHandler(cvPixelBuffer: current, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return .identity
            }
            guard
                let observation = request.results?.first as? VNImageTranslationAlignmentObservation
            else {
                return .identity
            }
            // alignmentTransform translation is in pixels, Core Image (bottom-left) origin. Convert to
            // normalized top-left: x unchanged, y flipped.
            // NOTE: if CMC makes IDs *worse* on-device, the most likely culprit is a sign here — flip
            // `translationY` (Vision's pixel-space y origin).
            let transform = observation.alignmentTransform
            let translationX = Float(transform.tx) / Float(width)
            let translationY = -Float(transform.ty) / Float(height)
            guard abs(translationX) < 0.5, abs(translationY) < 0.5 else { return .identity }
            return CameraMotion(translationX: translationX, translationY: translationY)
        }

        private func estimateHomography(
            previous: CVPixelBuffer,
            current: CVPixelBuffer
        ) -> CameraMotion {
            let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: previous)
            let handler = VNImageRequestHandler(cvPixelBuffer: current, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return .identity
            }
            guard
                let observation = request.results?.first as? VNImageHomographicAlignmentObservation
            else {
                return .identity
            }
            // warpTransform is a normalized homography with a lower-left origin. Conjugate by the y-flip
            // (`y' = 1 - y`) to express it on normalized top-left points. Best-effort — validate
            // on-device; `.translational` is the robust default.
            let flip = simd_float3x3(
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, -1, 0),
                SIMD3<Float>(0, 1, 1)
            )
            let topLeft = flip * observation.warpTransform * flip
            let motion = CameraMotion(transform: topLeft)
            // Reject a wild homography (registration failure) by checking the frame centre maps nearby.
            let center = motion.apply(to: TrackBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2)).center
            guard abs(center.x - 0.5) < 0.5, abs(center.y - 0.5) < 0.5 else { return .identity }
            return motion
        }
    }
#endif
