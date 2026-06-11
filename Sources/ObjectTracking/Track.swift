import Foundation
import simd

// MARK: - Track

/// One tracked object with a stable identity that persists across frames and brief detection gaps.
///
/// Public surface is read-only state for the consumer (`id`, `label`, `confidence`, `depth`, `box`,
/// `hits`, `timeSinceUpdate`); the predict/update/association machinery is module-internal and driven
/// by `MultiObjectTracker`.
public final class Track {
    public let id = UUID()
    public private(set) var label: String
    public private(set) var confidence: Float
    public private(set) var depth: Float?
    public private(set) var hits: Int = 1
    public private(set) var timeSinceUpdate: Int = 0

    /// Real elapsed time (seconds) since the last real observation — accumulated across coasted frames
    /// so OC-SORT re-seeds velocity correctly even under irregular frame cadence.
    private var coastedSeconds: Float = 0

    private var centerX: ScalarKalman
    private var centerY: ScalarKalman
    private var width: ScalarKalman
    private var height: ScalarKalman

    /// Centre of the last *real* observation, for OC-SORT virtual-trajectory re-update.
    private var lastObservedCenter: SIMD2<Float>
    /// Box of the last *real* observation, for OC-SORT Observation-Centric Recovery.
    private var lastObservedBox: TrackBox
    /// Recent observed centres (newest last), driving OCM velocity-direction consistency.
    private var observationHistory: [SIMD2<Float>]
    /// Accumulated camera motion since the last real observation, so OCR can warp the (stale)
    /// last-observed box into the current frame.
    private var coastMotion: CameraMotion = .identity

    private static let maxHistory = 8

    init(
        detection: Detection,
        config: TrackerConfiguration
    ) {
        let box = detection.box
        let center = box.center
        centerX = ScalarKalman(
            value: center.x,
            processNoise: config.processNoise,
            measurementNoise: config.measurementNoise
        )
        centerY = ScalarKalman(
            value: center.y,
            processNoise: config.processNoise,
            measurementNoise: config.measurementNoise
        )
        width = ScalarKalman(
            value: box.width,
            processNoise: config.processNoise,
            measurementNoise: config.measurementNoise
        )
        height = ScalarKalman(
            value: box.height,
            processNoise: config.processNoise,
            measurementNoise: config.measurementNoise
        )
        label = detection.label
        confidence = detection.confidence
        depth = detection.depth
        lastObservedCenter = center
        lastObservedBox = box
        observationHistory = [center]
    }

    /// Current (possibly predicted) box from the filter state.
    public var box: TrackBox {
        let w = max(width.value, 0.0001)
        let h = max(height.value, 0.0001)
        return TrackBox(
            x: centerX.value - w * 0.5,
            y: centerY.value - h * 0.5,
            width: w,
            height: h
        )
    }

    /// The last *observed* box warped into the current frame by accumulated camera motion — the anchor
    /// OC-SORT Observation-Centric Recovery matches against (not the drifted prediction).
    var recoveryBox: TrackBox {
        coastMotion.isIdentity ? lastObservedBox : coastMotion.apply(to: lastObservedBox)
    }

    /// Coast the track forward one frame (no measurement).
    func predict(dt: Float) {
        centerX.predict(dt: dt)
        centerY.predict(dt: dt)
        width.predict(dt: dt)
        height.predict(dt: dt)
        timeSinceUpdate += 1
        coastedSeconds += dt
    }

    /// Shift the prediction into the current frame to cancel camera motion (BoT-SORT CMC), and
    /// accumulate that motion so `recoveryBox` stays valid across the gap.
    func applyCameraMotion(_ motion: CameraMotion) {
        let warped = motion.apply(to: box)
        let center = warped.center
        centerX.recenter(to: center.x)
        centerY.recenter(to: center.y)
        width.recenter(to: warped.width)
        height.recenter(to: warped.height)
        coastMotion = motion.composed(after: coastMotion)
    }

    /// OCM cost input: cosine of the angle between the track's established motion direction (over the
    /// last `deltaFrames` observations) and the direction toward a candidate detection centre. Returns
    /// `0` (neutral) when there isn't enough history or motion to judge.
    func directionConsistency(
        toCenter candidate: SIMD2<Float>,
        deltaFrames: Int
    ) -> Float {
        guard observationHistory.count >= 2 else { return 0 }
        let last = observationHistory[observationHistory.count - 1]
        let backIndex = max(0, observationHistory.count - 1 - deltaFrames)
        let previous = observationHistory[backIndex]
        let established = last - previous
        let toward = candidate - last
        let establishedLength = simd_length(established)
        let towardLength = simd_length(toward)
        guard establishedLength > 1e-5, towardLength > 1e-5 else { return 0 }
        return simd_dot(established, toward) / (establishedLength * towardLength)
    }

    /// Correct the track with a matched detection.
    func update(
        with detection: Detection,
        config: TrackerConfiguration
    ) {
        let box = detection.box
        let measured = box.center

        // OC-SORT Observation-Centric Re-Update: after a coasting gap, re-seed velocity from the
        // straight-line trajectory between the last real observation and this one, then replay virtual
        // observations along that trajectory to settle the position/covariance that pure coasting
        // inflated. Uses real accumulated elapsed time so the estimate is correct under irregular
        // cadence.
        if timeSinceUpdate > 1 {
            let span = max(coastedSeconds, 0.0001)
            centerX.setVelocity((measured.x - lastObservedCenter.x) / span)
            centerY.setVelocity((measured.y - lastObservedCenter.y) / span)

            let gap = timeSinceUpdate
            if gap >= 2 {
                for step in 1..<gap {
                    let fraction = Float(step) / Float(gap)
                    centerX.update(lastObservedCenter.x + (measured.x - lastObservedCenter.x) * fraction)
                    centerY.update(lastObservedCenter.y + (measured.y - lastObservedCenter.y) * fraction)
                }
            }
        }

        centerX.update(measured.x)
        centerY.update(measured.y)
        width.update(box.width)
        height.update(box.height)

        label = detection.label
        confidence = detection.confidence
        if let newDepth = detection.depth {
            if let current = depth {
                depth = current + (newDepth - current) * config.depthSmoothing
            } else {
                depth = newDepth
            }
        }
        hits += 1
        timeSinceUpdate = 0
        coastedSeconds = 0
        coastMotion = .identity
        lastObservedCenter = measured
        lastObservedBox = box
        appendObservation(measured)
    }

    private func appendObservation(_ center: SIMD2<Float>) {
        observationHistory.append(center)
        if observationHistory.count > Self.maxHistory {
            observationHistory.removeFirst(observationHistory.count - Self.maxHistory)
        }
    }
}
