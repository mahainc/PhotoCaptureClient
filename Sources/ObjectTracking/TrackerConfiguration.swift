// MARK: - CameraMotionMode

/// How the tracker compensates for *camera* (not object) motion between frames — BoT-SORT's CMC.
public enum CameraMotionMode: Sendable, Equatable {
    /// No compensation: track predictions move by object velocity only.
    case off
    /// Compensate for global translation (pan/tilt). Cheap and robust — the default for a handheld
    /// phone.
    case translational
    /// Compensate for a full homography (translation + rotation + perspective). More capable but can be
    /// unstable on low-texture scenes.
    case homographic
}

// MARK: - TrackerConfiguration

/// Tuning for the multi-object tracker. Defaults target ≤~10 objects at ~3 fps from a handheld phone.
public struct TrackerConfiguration: Sendable, Equatable {
    /// First-stage association + new-track creation threshold (ByteTrack "high").
    public var highConfidence: Float
    /// Second-stage recovery threshold (ByteTrack "low") — low-score boxes only maintain tracks.
    public var lowConfidence: Float
    /// Minimum IoU for a track↔detection match.
    public var iouThreshold: Float
    /// Detections required before a track is emitted (suppresses one-frame spurious boxes).
    public var minHits: Int
    /// Frames a track may coast (be predicted without a detection) before deletion.
    public var maxAge: Int
    /// Kalman process / measurement noise (normalized units).
    public var processNoise: Float
    public var measurementNoise: Float
    /// EMA factor applied to a track's depth on each update (0 = frozen, 1 = no smoothing).
    public var depthSmoothing: Float
    /// Clamp for the inter-frame `dt` so an irregular cadence can't fling predictions.
    public var minDt: Float
    public var maxDt: Float
    /// OC-SORT Observation-Centric Momentum: weight of the velocity-direction consistency term added to
    /// the IoU association cost (paper λ = 0.2). `0` disables OCM. Only re-ranks among IoU-valid
    /// candidates — never matches a zero-IoU pair.
    public var ocmWeight: Float
    /// How many frames back the OCM direction is measured over (paper Δt = 3).
    public var ocmDeltaFrames: Int
    /// OC-SORT Observation-Centric Recovery: a final association pass matching still-unmatched tracks to
    /// leftover high-score detections by their last *observed* box (not the drifted prediction).
    public var enableOCR: Bool
    /// Camera-motion compensation mode (BoT-SORT CMC). Predictions are warped by the estimated global
    /// motion before association.
    public var cameraMotion: CameraMotionMode

    public init(
        highConfidence: Float = 0.6,
        lowConfidence: Float = 0.25,
        iouThreshold: Float = 0.2,
        minHits: Int = 2,
        maxAge: Int = 3,
        processNoise: Float = 0.02,
        measurementNoise: Float = 0.05,
        depthSmoothing: Float = 0.6,
        minDt: Float = 0.05,
        maxDt: Float = 1.0,
        ocmWeight: Float = 0.2,
        ocmDeltaFrames: Int = 3,
        enableOCR: Bool = true,
        cameraMotion: CameraMotionMode = .translational
    ) {
        self.highConfidence = highConfidence
        self.lowConfidence = lowConfidence
        self.iouThreshold = iouThreshold
        self.minHits = minHits
        self.maxAge = maxAge
        self.processNoise = processNoise
        self.measurementNoise = measurementNoise
        self.depthSmoothing = depthSmoothing
        self.minDt = minDt
        self.maxDt = maxDt
        self.ocmWeight = ocmWeight
        self.ocmDeltaFrames = ocmDeltaFrames
        self.enableOCR = enableOCR
        self.cameraMotion = cameraMotion
    }
}
