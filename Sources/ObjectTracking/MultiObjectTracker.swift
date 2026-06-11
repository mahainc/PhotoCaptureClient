// MARK: - Multi-Object Tracker

/// Track-by-detection associator combining, clean-room from their papers (see
/// `ObjectTrackingAttribution`):
/// - **SORT** — per-axis constant-velocity Kalman prediction + greedy IoU matching;
/// - **ByteTrack** — two-stage association that recovers momentarily low-confidence boxes;
/// - **OC-SORT** — Observation-Centric Momentum (velocity-direction cost), Re-Update (virtual
///   trajectory after a gap), and Recovery (match by last observation);
/// - **BoT-SORT CMC** — warp predictions by the estimated camera motion before association;
/// - **coasting** — keep emitting briefly-missed tracks (`minHits` / `maxAge` hysteresis).
///
/// Turns identity-less per-frame detections into objects with stable IDs. Single-threaded; drive it
/// from one isolation domain (the detection actor).
public final class MultiObjectTracker {
    private var tracks: [Track] = []
    private let config: TrackerConfiguration

    public init(config: TrackerConfiguration) {
        self.config = config
    }

    public func reset() {
        tracks.removeAll()
    }

    /// Advance one detection frame and return the live (confirmed) tracks, including ones currently
    /// coasting through a missed detection.
    ///
    /// - Parameters:
    ///   - detections: this frame's raw detections (any confidence ≥ `lowConfidence`).
    ///   - rawDt: seconds since the previous frame (clamped to `[minDt, maxDt]`).
    ///   - cameraMotion: estimated previous→current global motion; ignored when `nil`, identity, or
    ///     `config.cameraMotion == .off`.
    public func update(
        detections: [Detection],
        dt rawDt: Float,
        cameraMotion: CameraMotion? = nil
    ) -> [Track] {
        let dt = min(max(rawDt, config.minDt), config.maxDt)

        // 1. Predict every existing track forward.
        for track in tracks {
            track.predict(dt: dt)
        }

        // 2. Camera-motion compensation: warp predictions into the current frame (BoT-SORT CMC).
        if config.cameraMotion != .off, let motion = cameraMotion, !motion.isIdentity {
            for track in tracks {
                track.applyCameraMotion(motion)
            }
        }

        // 3. ByteTrack split.
        let high = detections.filter { $0.confidence >= config.highConfidence }
        let low = detections.filter {
            $0.confidence >= config.lowConfidence && $0.confidence < config.highConfidence
        }

        var unmatched = Set(tracks.indices)
        var matchedHigh = Set<Int>()

        // 4. First association: tracks ↔ high-score detections, cost = IoU + OCM momentum.
        for (trackIndex, detectionIndex) in associate(
            trackIndices: Array(unmatched),
            detections: high,
            useMomentum: true
        ) {
            tracks[trackIndex].update(with: high[detectionIndex], config: config)
            unmatched.remove(trackIndex)
            matchedHigh.insert(detectionIndex)
        }

        // 5. Second association (ByteTrack): leftover tracks ↔ low-score detections, IoU only.
        for (trackIndex, detectionIndex) in associate(
            trackIndices: Array(unmatched),
            detections: low,
            useMomentum: false
        ) {
            tracks[trackIndex].update(with: low[detectionIndex], config: config)
            unmatched.remove(trackIndex)
        }

        // 6. OC-SORT Observation-Centric Recovery: still-unmatched tracks ↔ leftover high-score
        //    detections, matched against each track's last *observed* box (CMC-warped) rather than its
        //    drifted prediction.
        if config.enableOCR, !unmatched.isEmpty {
            let leftoverHigh = high.indices.filter { !matchedHigh.contains($0) }
            for (trackIndex, leftoverSlot) in associateRecovery(
                trackIndices: Array(unmatched),
                detectionIndices: leftoverHigh,
                detections: high
            ) {
                let detectionIndex = leftoverHigh[leftoverSlot]
                tracks[trackIndex].update(with: high[detectionIndex], config: config)
                unmatched.remove(trackIndex)
                matchedHigh.insert(detectionIndex)
            }
        }

        // 7. Unmatched high-score detections start new (tentative) tracks.
        for (index, detection) in high.enumerated() where !matchedHigh.contains(index) {
            tracks.append(Track(detection: detection, config: config))
        }

        // 8. Retire tracks that have coasted too long.
        tracks.removeAll { $0.timeSinceUpdate > config.maxAge }

        // 9. Emit confirmed tracks (measured this frame or briefly coasting).
        return tracks.filter { $0.hits >= config.minHits }
    }

    /// Greedy association by IoU (optionally + OCM momentum). Repeatedly take the highest-scoring
    /// (track, detection) pair whose IoU clears the threshold. Optimal-enough for ≤~10 objects and far
    /// simpler than Hungarian. OCM only *re-ranks* IoU-valid candidates — the threshold gate is always
    /// on IoU, so momentum can never invent a match.
    private func associate(
        trackIndices: [Int],
        detections: [Detection],
        useMomentum: Bool
    ) -> [(track: Int, detection: Int)] {
        guard !trackIndices.isEmpty, !detections.isEmpty else { return [] }

        var candidates: [(track: Int, detection: Int, score: Float)] = []
        for trackIndex in trackIndices {
            let trackBox = tracks[trackIndex].box
            for (detectionIndex, detection) in detections.enumerated() {
                let iou = TrackBox.iou(trackBox, detection.box)
                guard iou >= config.iouThreshold else { continue }
                var score = iou
                if useMomentum, config.ocmWeight > 0 {
                    let consistency = tracks[trackIndex].directionConsistency(
                        toCenter: detection.box.center,
                        deltaFrames: config.ocmDeltaFrames
                    )
                    score += config.ocmWeight * consistency
                }
                candidates.append((trackIndex, detectionIndex, score))
            }
        }
        return greedyMatch(candidates)
    }

    /// OCR association: match by the track's CMC-warped last-observed box instead of its prediction.
    private func associateRecovery(
        trackIndices: [Int],
        detectionIndices: [Int],
        detections: [Detection]
    ) -> [(track: Int, detection: Int)] {
        guard !trackIndices.isEmpty, !detectionIndices.isEmpty else { return [] }

        var candidates: [(track: Int, detection: Int, score: Float)] = []
        for trackIndex in trackIndices {
            let anchor = tracks[trackIndex].recoveryBox
            for (slot, detectionIndex) in detectionIndices.enumerated() {
                let iou = TrackBox.iou(anchor, detections[detectionIndex].box)
                if iou >= config.iouThreshold {
                    candidates.append((trackIndex, slot, iou))
                }
            }
        }
        return greedyMatch(candidates)
    }

    /// Resolve scored candidates greedily, highest first, one detection per track and vice versa.
    private func greedyMatch(
        _ candidates: [(track: Int, detection: Int, score: Float)]
    ) -> [(track: Int, detection: Int)] {
        let ordered = candidates.sorted { $0.score > $1.score }
        var usedTracks = Set<Int>()
        var usedDetections = Set<Int>()
        var matches: [(track: Int, detection: Int)] = []
        for candidate in ordered {
            if usedTracks.contains(candidate.track) || usedDetections.contains(candidate.detection) {
                continue
            }
            usedTracks.insert(candidate.track)
            usedDetections.insert(candidate.detection)
            matches.append((candidate.track, candidate.detection))
        }
        return matches
    }
}
