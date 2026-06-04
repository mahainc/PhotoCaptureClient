import Foundation
import ObjectDetectionClient

// MARK: - Tracker Detection

/// A single raw detection fed into the tracker: a normalized top-left box plus its class and the
/// depth sampled at its centre.
struct TrackerDetection {
    let box: ObjectDetectionClient.BoundingBox
    let confidence: Float
    let label: String
    let depth: Float?
}

// MARK: - Tracker Configuration

/// Tuning for the multi-object tracker. Defaults target ≤~10 objects at ~3 fps.
struct TrackerConfiguration {
    /// First-stage association + new-track creation threshold (ByteTrack "high").
    var highConfidence: Float = 0.6
    /// Second-stage recovery threshold (ByteTrack "low") — low-score boxes only maintain tracks.
    var lowConfidence: Float = 0.25
    /// Minimum IoU for a track↔detection match.
    var iouThreshold: Float = 0.2
    /// Detections required before a track is emitted (suppresses one-frame spurious boxes).
    var minHits: Int = 2
    /// Frames a track may coast (be predicted without a detection) before deletion.
    var maxAge: Int = 3
    /// Kalman process / measurement noise (normalized units).
    var processNoise: Float = 0.02
    var measurementNoise: Float = 0.05
    /// EMA factor applied to a track's depth on each update (0 = frozen, 1 = no smoothing).
    var depthSmoothing: Float = 0.6
    /// Clamp for the inter-frame `dt` so an irregular cadence can't fling predictions.
    var minDt: Float = 0.05
    var maxDt: Float = 1.0
}

// MARK: - Scalar Kalman (constant velocity)

/// A minimal 2-state (position, velocity) constant-velocity Kalman filter. Four per track
/// (cx, cy, width, height) give SORT-style prediction + smoothing without 7×7 matrix math —
/// sufficient for a handful of large objects at ~3 fps.
private struct ScalarKalman {
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
}

// MARK: - Track

/// One tracked object with a stable identity that persists across frames and brief detection gaps.
final class Track {
    let id = UUID()
    private(set) var label: String
    private(set) var confidence: Float
    private(set) var depth: Float?
    private(set) var hits: Int = 1
    private(set) var timeSinceUpdate: Int = 0
    /// Real elapsed time (seconds) since the last real observation — accumulated across coasted
    /// frames so OC-SORT re-seeds velocity correctly even under irregular frame cadence.
    private var coastedSeconds: Float = 0

    private var centerX: ScalarKalman
    private var centerY: ScalarKalman
    private var width: ScalarKalman
    private var height: ScalarKalman
    /// Centre of the last *real* observation, for OC-SORT virtual-trajectory re-update.
    private var lastObservedCenter: (x: Float, y: Float)

    init(
        detection: TrackerDetection,
        config: TrackerConfiguration
    ) {
        let box = detection.box
        let cx = box.x + box.width * 0.5
        let cy = box.y + box.height * 0.5
        centerX = ScalarKalman(value: cx, processNoise: config.processNoise, measurementNoise: config.measurementNoise)
        centerY = ScalarKalman(value: cy, processNoise: config.processNoise, measurementNoise: config.measurementNoise)
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
        lastObservedCenter = (cx, cy)
    }

    /// Current (possibly predicted) box from the filter state.
    var box: ObjectDetectionClient.BoundingBox {
        let w = max(width.value, 0.0001)
        let h = max(height.value, 0.0001)
        return ObjectDetectionClient.BoundingBox(
            x: centerX.value - w * 0.5,
            y: centerY.value - h * 0.5,
            width: w,
            height: h
        )
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

    /// Correct the track with a matched detection.
    func update(
        with detection: TrackerDetection,
        config: TrackerConfiguration
    ) {
        let box = detection.box
        let measuredX = box.x + box.width * 0.5
        let measuredY = box.y + box.height * 0.5

        // OC-SORT observation-centric re-update: after a coasting gap, re-seed velocity from the
        // straight-line trajectory between the last real observation and this one, undoing the drift
        // that pure linear coasting accumulates. Use real accumulated elapsed time so the estimate is
        // correct even when frame cadence is irregular.
        if timeSinceUpdate > 1 {
            let span = max(coastedSeconds, 0.0001)
            centerX.setVelocity((measuredX - lastObservedCenter.x) / span)
            centerY.setVelocity((measuredY - lastObservedCenter.y) / span)
        }

        centerX.update(measuredX)
        centerY.update(measuredY)
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
        lastObservedCenter = (measuredX, measuredY)
    }
}

// MARK: - Multi-Object Tracker

/// Track-by-detection associator: SORT-style Kalman prediction + greedy IoU matching, ByteTrack
/// two-stage association (recovers low-confidence boxes), OC-SORT observation-centric re-update, and
/// coasting through brief dropouts — turning identity-less per-frame detections into objects with
/// stable IDs. Single-threaded; drive it from one isolation domain (the detection actor).
final class MultiObjectTracker {
    private var tracks: [Track] = []
    private let config: TrackerConfiguration

    init(config: TrackerConfiguration) {
        self.config = config
    }

    func reset() {
        tracks.removeAll()
    }

    /// Advance one detection frame and return the live (confirmed) tracks, including ones currently
    /// coasting through a missed detection.
    func update(
        detections: [TrackerDetection],
        dt rawDt: Float
    ) -> [Track] {
        let dt = min(max(rawDt, config.minDt), config.maxDt)

        // 1. Predict every existing track forward.
        for track in tracks {
            track.predict(dt: dt)
        }

        // 2. ByteTrack split.
        let high = detections.filter { $0.confidence >= config.highConfidence }
        let low = detections.filter {
            $0.confidence >= config.lowConfidence && $0.confidence < config.highConfidence
        }

        var unmatched = Set(tracks.indices)

        // 3. First association: tracks ↔ high-score detections.
        var matchedHigh = Set<Int>()
        for (trackIndex, detectionIndex) in associate(trackIndices: Array(unmatched), detections: high) {
            tracks[trackIndex].update(with: high[detectionIndex], config: config)
            unmatched.remove(trackIndex)
            matchedHigh.insert(detectionIndex)
        }

        // 4. Second association (ByteTrack): leftover tracks ↔ low-score detections.
        for (trackIndex, detectionIndex) in associate(trackIndices: Array(unmatched), detections: low) {
            tracks[trackIndex].update(with: low[detectionIndex], config: config)
            unmatched.remove(trackIndex)
        }

        // 5. Unmatched high-score detections start new (tentative) tracks.
        for (index, detection) in high.enumerated() where !matchedHigh.contains(index) {
            tracks.append(Track(detection: detection, config: config))
        }

        // 6. Retire tracks that have coasted too long.
        tracks.removeAll { $0.timeSinceUpdate > config.maxAge }

        // 7. Emit confirmed tracks (measured this frame or briefly coasting).
        return tracks.filter { $0.hits >= config.minHits }
    }

    /// Greedy IoU association — repeatedly take the highest-IoU (track, detection) pair above the
    /// threshold. Optimal-enough for ≤~10 objects and far simpler than Hungarian.
    private func associate(
        trackIndices: [Int],
        detections: [TrackerDetection]
    ) -> [(track: Int, detection: Int)] {
        guard !trackIndices.isEmpty, !detections.isEmpty else { return [] }

        var candidates: [(track: Int, detection: Int, iou: Float)] = []
        for trackIndex in trackIndices {
            let trackBox = tracks[trackIndex].box
            for (detectionIndex, detection) in detections.enumerated() {
                let score = Self.iou(trackBox, detection.box)
                if score >= config.iouThreshold {
                    candidates.append((trackIndex, detectionIndex, score))
                }
            }
        }
        candidates.sort { $0.iou > $1.iou }

        var usedTracks = Set<Int>()
        var usedDetections = Set<Int>()
        var matches: [(track: Int, detection: Int)] = []
        for candidate in candidates {
            if usedTracks.contains(candidate.track) || usedDetections.contains(candidate.detection) {
                continue
            }
            usedTracks.insert(candidate.track)
            usedDetections.insert(candidate.detection)
            matches.append((candidate.track, candidate.detection))
        }
        return matches
    }

    private static func iou(
        _ a: ObjectDetectionClient.BoundingBox,
        _ b: ObjectDetectionClient.BoundingBox
    ) -> Float {
        let interX1 = max(a.x, b.x)
        let interY1 = max(a.y, b.y)
        let interX2 = min(a.x + a.width, b.x + b.width)
        let interY2 = min(a.y + a.height, b.y + b.height)
        let interW = max(0, interX2 - interX1)
        let interH = max(0, interY2 - interY1)
        let intersection = interW * interH
        let union = a.width * a.height + b.width * b.height - intersection
        return union > 0 ? intersection / union : 0
    }
}
