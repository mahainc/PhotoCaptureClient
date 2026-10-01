import Dependencies
import Foundation

// MARK: - Dependency Registration

extension DependencyValues {
    public var objectDetection: ObjectDetectionClient {
        get { self[ObjectDetectionClient.self] }
        set { self[ObjectDetectionClient.self] = newValue }
    }
}

// MARK: - Test Dependency Key

extension ObjectDetectionClient: TestDependencyKey {
    public static let previewValue = Self.happy
    public static let testValue = Self()
}

// MARK: - Mock Constants

private enum MockConstants {
    static let modelLoadDelayNanoseconds: UInt64 = 500_000_000  // 500ms
    static let inferenceDelayNanoseconds: UInt64 = 50_000_000   // 50ms
}

// MARK: - Mock Implementations

extension ObjectDetectionClient {
    /// All operations do nothing. Returns manual mode and empty results.
    public static let noop = Self(
        currentMode: { .manual },
        startDetection: { _ in },
        stopDetection: { },
        detectionResults: { AsyncStream { _ in } },
        detectInImage: { _ in DetectionResult() }
    )

    /// Returns realistic mock data with delays.
    public static let happy = Self(
        currentMode: { .auto },
        startDetection: { _ in
            try await Task.sleep(nanoseconds: MockConstants.modelLoadDelayNanoseconds)
        },
        stopDetection: { },
        detectionResults: {
            AsyncStream { continuation in
                Task {
                    try? await Task.sleep(nanoseconds: MockConstants.inferenceDelayNanoseconds)
                    continuation.yield(DetectionResult(
                        objects: [
                            DetectedObject(
                                label: "person",
                                confidence: 0.92,
                                boundingBox: BoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.6)
                            ),
                            DetectedObject(
                                label: "laptop",
                                confidence: 0.87,
                                boundingBox: BoundingBox(x: 0.5, y: 0.4, width: 0.2, height: 0.15)
                            ),
                        ],
                        inferenceTimeMs: 35.0,
                        timestamp: .now
                    ))
                }
            }
        },
        detectInImage: { _ in
            try await Task.sleep(nanoseconds: MockConstants.inferenceDelayNanoseconds)
            return DetectionResult(
                objects: [
                    DetectedObject(
                        label: "cat",
                        confidence: 0.95,
                        boundingBox: BoundingBox(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
                    ),
                ],
                inferenceTimeMs: 42.0,
                timestamp: .now
            )
        }
    )

    /// One object held in view, ageing, and maturing once.
    ///
    /// The `happy` mock mints a fresh `UUID` on every emission, which makes it useless for
    /// anything keyed on track identity — a consumer timing a dwell sees a brand-new
    /// object each frame and never accumulates. This one keeps a single id across the whole
    /// stream and raises `trackedSeconds` with it, then reports the object as matured on
    /// the frame it crosses `dwellSeconds`, exactly once.
    public static func dwelling(
        dwellSeconds: TimeInterval = 2,
        frameInterval: TimeInterval = 0.333,
        frames: Int = 12
    ) -> Self {
        let id = UUID()
        let box = BoundingBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        return Self(
            currentMode: { .auto },
            startDetection: { _ in },
            stopDetection: {},
            detectionResults: {
                AsyncStream { continuation in
                    Task {
                        var matured = false
                        for frame in 0..<frames {
                            let age = TimeInterval(frame) * frameInterval
                            let isMaturingNow = !matured && age >= dwellSeconds
                            if isMaturingNow { matured = true }
                            continuation.yield(
                                DetectionResult(
                                    objects: [
                                        DetectedObject(
                                            id: id,
                                            label: "mug",
                                            confidence: 0.9,
                                            boundingBox: box,
                                            trackedSeconds: age
                                        )
                                    ],
                                    maturedObjects: isMaturingNow
                                        ? [MaturedObject(id: id, label: "mug", croppedData: Data())]
                                        : [],
                                    inferenceTimeMs: 20,
                                    timestamp: .now
                                )
                            )
                        }
                        continuation.finish()
                    }
                }
            },
            detectInImage: { _ in DetectionResult() }
        )
    }

    /// All operations that can fail throw errors.
    public static let failing = Self(
        currentMode: { .manual },
        startDetection: { _ in
            throw ObjectDetectionClient.Error.modelLoadFailed("Mock model load failure")
        },
        stopDetection: { },
        detectionResults: { AsyncStream { $0.finish() } },
        detectInImage: { _ in
            throw ObjectDetectionClient.Error.inferenceFailed("Mock inference failure")
        }
    )
}
