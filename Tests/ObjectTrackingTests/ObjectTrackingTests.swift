import XCTest

@testable import ObjectTracking

final class ObjectTrackingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a detection from a centre point (default 0.2×0.2 box).
    private func det(
        _ centerX: Float,
        _ centerY: Float,
        size: Float = 0.2,
        confidence: Float = 0.9,
        label: String = "obj",
        depth: Float? = nil
    ) -> Detection {
        Detection(
            box: TrackBox(
                x: centerX - size * 0.5,
                y: centerY - size * 0.5,
                width: size,
                height: size
            ),
            confidence: confidence,
            label: label,
            depth: depth
        )
    }

    private let dt: Float = 0.333

    // MARK: - TrackBox geometry

    func testIoUIdenticalIsOne() {
        let box = TrackBox(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertEqual(TrackBox.iou(box, box), 1, accuracy: 1e-5)
    }

    func testIoUDisjointIsZero() {
        let boxA = TrackBox(x: 0.0, y: 0.0, width: 0.2, height: 0.2)
        let boxB = TrackBox(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        XCTAssertEqual(TrackBox.iou(boxA, boxB), 0, accuracy: 1e-5)
    }

    func testIoUHalfOverlap() {
        // Two equal boxes sharing exactly half their area → IoU = 1/3.
        let boxA = TrackBox(x: 0.0, y: 0.0, width: 0.2, height: 0.2)
        let boxB = TrackBox(x: 0.1, y: 0.0, width: 0.2, height: 0.2)
        XCTAssertEqual(TrackBox.iou(boxA, boxB), 1.0 / 3.0, accuracy: 1e-4)
    }

    // MARK: - Track lifecycle

    func testNewTrackRequiresMinHits() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration())
        // First sighting: tentative, not emitted (hits = 1 < minHits = 2).
        XCTAssertTrue(tracker.update(detections: [det(0.5, 0.5)], dt: dt).isEmpty)
        // Second sighting confirms it.
        let confirmed = tracker.update(detections: [det(0.51, 0.5)], dt: dt)
        XCTAssertEqual(confirmed.count, 1)
    }

    func testStableIDAcrossFrames() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration())
        _ = tracker.update(detections: [det(0.50, 0.5)], dt: dt)
        let first = tracker.update(detections: [det(0.52, 0.5)], dt: dt)
        XCTAssertEqual(first.count, 1)
        let id = first[0].id

        for centerX in stride(from: Float(0.54), through: 0.62, by: 0.02) {
            let tracks = tracker.update(detections: [det(centerX, 0.5)], dt: dt)
            XCTAssertEqual(tracks.count, 1)
            XCTAssertEqual(tracks[0].id, id, "track identity must persist across frames")
        }
    }

    func testTwoObjectsKeepSeparateIDs() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration())
        _ = tracker.update(detections: [det(0.25, 0.25, label: "A"), det(0.75, 0.75, label: "B")], dt: dt)
        let tracks = tracker.update(
            detections: [det(0.26, 0.25, label: "A"), det(0.74, 0.75, label: "B")],
            dt: dt
        )
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(Set(tracks.map { $0.id }).count, 2, "the two objects must hold distinct IDs")
    }

    func testReset() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration())
        _ = tracker.update(detections: [det(0.5, 0.5)], dt: dt)
        _ = tracker.update(detections: [det(0.5, 0.5)], dt: dt)
        tracker.reset()
        XCTAssertTrue(tracker.update(detections: [], dt: dt).isEmpty)
    }

    // MARK: - Coasting + OC-SORT re-update (ORU)

    func testCoastsThroughDropoutAndKeepsID() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration())
        _ = tracker.update(detections: [det(0.50, 0.5)], dt: dt)
        let confirmed = tracker.update(detections: [det(0.52, 0.5)], dt: dt)
        let id = confirmed[0].id

        // Two consecutive frames with NO detection — within maxAge (3), the track keeps coasting and
        // stays emitted with the same ID.
        let coast1 = tracker.update(detections: [], dt: dt)
        XCTAssertEqual(coast1.count, 1)
        XCTAssertEqual(coast1[0].id, id)
        let coast2 = tracker.update(detections: [], dt: dt)
        XCTAssertEqual(coast2.count, 1)
        XCTAssertEqual(coast2[0].id, id)

        // Re-acquire after the gap (triggers OC-SORT observation-centric re-update). Same ID, and the
        // box snaps back onto the new observation rather than the coasted prediction.
        let reacquired = tracker.update(detections: [det(0.56, 0.5)], dt: dt)
        XCTAssertEqual(reacquired.count, 1)
        XCTAssertEqual(reacquired[0].id, id)
        XCTAssertEqual(reacquired[0].box.center.x, 0.56, accuracy: 0.04)
    }

    func testTrackRetiresAfterMaxAge() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration(maxAge: 2))
        _ = tracker.update(detections: [det(0.5, 0.5)], dt: dt)
        _ = tracker.update(detections: [det(0.5, 0.5)], dt: dt)
        // maxAge = 2 → emitted while coasting frames 1 and 2, gone on frame 3.
        XCTAssertEqual(tracker.update(detections: [], dt: dt).count, 1)
        XCTAssertEqual(tracker.update(detections: [], dt: dt).count, 1)
        XCTAssertTrue(tracker.update(detections: [], dt: dt).isEmpty)
    }

    // MARK: - Crossing (exercises OCM; asserts no ID swap)

    func testNoIDSwapThroughCrossing() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration())
        // A moves right along y = 0.45; B moves left along y = 0.55 (a 0.10 vertical gap keeps the
        // assignment well-posed while the boxes overlap heavily through the crossing).
        _ = tracker.update(
            detections: [det(0.30, 0.45, label: "A"), det(0.70, 0.55, label: "B")],
            dt: dt
        )
        let confirmed = tracker.update(
            detections: [det(0.40, 0.45, label: "A"), det(0.60, 0.55, label: "B")],
            dt: dt
        )
        XCTAssertEqual(confirmed.count, 2)
        let leftStart = confirmed.min { $0.box.center.x < $1.box.center.x }!
        let rightStart = confirmed.max { $0.box.center.x < $1.box.center.x }!
        let idMovingRight = leftStart.id  // started on the left, heading right (the "A" object)
        let idMovingLeft = rightStart.id  // started on the right, heading left (the "B" object)

        // Crossing frame: both near x = 0.50.
        _ = tracker.update(detections: [det(0.50, 0.45), det(0.50, 0.55)], dt: dt)
        // After the crossing: each ID must have continued in its own direction, not swapped.
        let after = tracker.update(detections: [det(0.60, 0.45), det(0.40, 0.55)], dt: dt)
        let right = after.first { $0.id == idMovingRight }
        let left = after.first { $0.id == idMovingLeft }
        XCTAssertNotNil(right, "the rightward object kept its ID")
        XCTAssertNotNil(left, "the leftward object kept its ID")
        XCTAssertGreaterThan(right!.box.center.x, 0.5)
        XCTAssertLessThan(left!.box.center.x, 0.5)
    }

    // MARK: - Camera-motion compensation (CMC)

    func testCameraMotionTranslatesBoxCentre() {
        let box = TrackBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2)  // centre (0.5, 0.5)
        let moved = CameraMotion(translationX: 0.1, translationY: -0.05).apply(to: box)
        XCTAssertEqual(moved.center.x, 0.6, accuracy: 1e-5)
        XCTAssertEqual(moved.center.y, 0.45, accuracy: 1e-5)
        XCTAssertEqual(moved.width, 0.2, accuracy: 1e-5, "pure translation must not rescale the box")
    }

    func testIdentityCameraMotion() {
        XCTAssertTrue(CameraMotion.identity.isIdentity)
        let box = TrackBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(CameraMotion.identity.apply(to: box), box)
    }

    func testCMCHoldsIDUnderGlobalTranslation() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration())
        // A stationary object, confirmed at centre 0.5.
        _ = tracker.update(detections: [det(0.5, 0.5)], dt: dt, cameraMotion: .identity)
        let confirmed = tracker.update(detections: [det(0.5, 0.5)], dt: dt, cameraMotion: .identity)
        let id = confirmed[0].id

        // The camera pans right by 0.2, so the (world-stationary) object now appears at x = 0.3 — a full
        // box-width away, IoU 0 vs the un-warped prediction. With CMC the prediction is warped by the
        // reported motion and the ID survives.
        let panned = tracker.update(
            detections: [det(0.3, 0.5)],
            dt: dt,
            cameraMotion: CameraMotion(translationX: -0.2, translationY: 0)
        )
        XCTAssertEqual(panned.count, 1)
        XCTAssertEqual(panned[0].id, id, "CMC should keep the ID across a large global shift")
    }

    func testWithoutCMCLargeShiftLosesTheBox() {
        // Same large shift but CMC off → the prediction can't reach the detection, so the original can't
        // re-match it this frame (a new tentative track forms instead). Confirms CMC is what saved the
        // ID above.
        let tracker = MultiObjectTracker(config: TrackerConfiguration(cameraMotion: .off))
        _ = tracker.update(detections: [det(0.5, 0.5)], dt: dt)
        let confirmed = tracker.update(detections: [det(0.5, 0.5)], dt: dt)
        let id = confirmed[0].id
        // Provide the motion, but mode is .off so it is ignored.
        let panned = tracker.update(
            detections: [det(0.3, 0.5)],
            dt: dt,
            cameraMotion: CameraMotion(translationX: -0.2, translationY: 0)
        )
        XCTAssertFalse(
            panned.contains { $0.id == id && $0.box.center.x < 0.4 },
            "without CMC the original track should not have jumped onto the shifted detection"
        )
    }

    // MARK: - Depth carry-through

    func testDepthIsEMASmoothed() {
        let tracker = MultiObjectTracker(config: TrackerConfiguration(depthSmoothing: 0.6))
        _ = tracker.update(detections: [det(0.5, 0.5, depth: 2.0)], dt: dt)
        let tracks = tracker.update(detections: [det(0.5, 0.5, depth: 1.0)], dt: dt)
        // First depth seeds (2.0); second blends: 2.0 + (1.0 - 2.0) * 0.6 = 1.4.
        XCTAssertEqual(tracks[0].depth ?? 0, 1.4, accuracy: 1e-4)
    }
}
