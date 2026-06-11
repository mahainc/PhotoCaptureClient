// MARK: - Scalar Kalman (constant velocity)

/// A minimal 2-state (position, velocity) constant-velocity Kalman filter. Four per track
/// (cx, cy, width, height) give SORT-style prediction + smoothing without 7×7 matrix math.
///
/// This decoupled per-axis model is a deliberate, documented simplification of BoT-SORT's 8-D
/// `[xc, yc, w, h, …]` state with a *diagonal* covariance — sufficient for a handful of large objects
/// at ~3 fps, and far cheaper than a coupled filter. (Clean-room from the SORT/BoT-SORT papers; see
/// `ObjectTrackingAttribution`.)
struct ScalarKalman {
    private(set) var value: Float
    private var velocity: Float = 0
    // 2×2 covariance [[p00, p01], [p10, p11]].
    private var p00: Float = 1
    private var p01: Float = 0
    private var p10: Float = 0
    private var p11: Float = 1
    private let processNoise: Float
    private let measurementNoise: Float

    init(
        value: Float,
        processNoise: Float,
        measurementNoise: Float
    ) {
        self.value = value
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
    }

    /// Advance the state by `dt` with F = [[1, dt], [0, 1]], P = F·P·Fᵀ + Q.
    mutating func predict(dt: Float) {
        value += velocity * dt
        let newP00 = p00 + dt * (p01 + p10) + dt * dt * p11 + processNoise
        let newP01 = p01 + dt * p11
        let newP10 = p10 + dt * p11
        let newP11 = p11 + processNoise
        p00 = newP00
        p01 = newP01
        p10 = newP10
        p11 = newP11
    }

    /// Correct with a measurement (H = [1, 0]).
    mutating func update(_ measurement: Float) {
        let innovationCovariance = p00 + measurementNoise
        guard innovationCovariance > 0 else { return }
        let k0 = p00 / innovationCovariance
        let k1 = p10 / innovationCovariance
        let residual = measurement - value
        value += k0 * residual
        velocity += k1 * residual
        let newP00 = (1 - k0) * p00
        let newP01 = (1 - k0) * p01
        let newP10 = p10 - k1 * p00
        let newP11 = p11 - k1 * p01
        p00 = newP00
        p01 = newP01
        p10 = newP10
        p11 = newP11
    }

    /// Force the velocity directly — used by OC-SORT observation-centric re-update after a gap.
    mutating func setVelocity(_ newVelocity: Float) {
        velocity = newVelocity
    }

    /// Re-seat the position without touching velocity or covariance — used by camera-motion
    /// compensation to shift a prediction into the current frame.
    mutating func recenter(to newValue: Float) {
        value = newValue
    }
}
