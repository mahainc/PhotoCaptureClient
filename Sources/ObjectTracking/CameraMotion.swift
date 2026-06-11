import simd

// MARK: - CameraMotion

/// A frame-to-frame global camera motion, expressed as a homogeneous 3×3 transform on **normalized
/// top-left** points (`[x, y, 1]` column vectors). Maps a point in the *previous* frame to where it
/// appears in the *current* frame. Pure value type with no Vision dependency — `CameraMotionEstimator`
/// produces it, the tracker consumes it to warp predictions (BoT-SORT CMC).
public struct CameraMotion: Sendable {
    public var transform: simd_float3x3

    /// No camera motion.
    public static let identity = CameraMotion(transform: matrix_identity_float3x3)

    public init(transform: simd_float3x3) {
        self.transform = transform
    }

    /// Pure translation in normalized top-left space.
    public init(
        translationX: Float,
        translationY: Float
    ) {
        var matrix = matrix_identity_float3x3
        matrix.columns.2 = SIMD3<Float>(translationX, translationY, 1)
        self.transform = matrix
    }

    public var isIdentity: Bool {
        transform.columns.0 == SIMD3<Float>(1, 0, 0)
            && transform.columns.1 == SIMD3<Float>(0, 1, 0)
            && transform.columns.2 == SIMD3<Float>(0, 0, 1)
    }

    /// Compose two motions: `self` applied *after* `earlier` (used to accumulate per-frame motion across
    /// a coasting gap).
    public func composed(after earlier: CameraMotion) -> CameraMotion {
        CameraMotion(transform: transform * earlier.transform)
    }

    /// Warp a box: its centre moves by the transform; for a homography the size scales by the local
    /// linear scale (no-op for pure translation).
    public func apply(to box: TrackBox) -> TrackBox {
        // A genuine no-op for identity — avoids a centre↔origin round-trip introducing ULP drift.
        guard !isIdentity else { return box }
        let center = box.center
        let projected = transform * SIMD3<Float>(center.x, center.y, 1)
        let w = projected.z != 0 ? projected.z : 1
        let newCenterX = projected.x / w
        let newCenterY = projected.y / w

        let scaleX = simd_length(SIMD2<Float>(transform.columns.0.x, transform.columns.0.y))
        let scaleY = simd_length(SIMD2<Float>(transform.columns.1.x, transform.columns.1.y))
        let newWidth = box.width * scaleX
        let newHeight = box.height * scaleY

        return TrackBox(
            x: newCenterX - newWidth * 0.5,
            y: newCenterY - newHeight * 0.5,
            width: newWidth,
            height: newHeight
        )
    }
}

extension CameraMotion: Equatable {
    public static func == (
        lhs: CameraMotion,
        rhs: CameraMotion
    ) -> Bool {
        lhs.transform.columns.0 == rhs.transform.columns.0
            && lhs.transform.columns.1 == rhs.transform.columns.1
            && lhs.transform.columns.2 == rhs.transform.columns.2
    }
}
