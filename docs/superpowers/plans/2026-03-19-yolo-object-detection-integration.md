# YOLO Object Detection Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Ultralytics YOLO object detection into PhotoCaptureClient as a dual-mode system — manual (default, no YOLO) and auto (YOLO-powered object detection on camera frames).

**Architecture:** Add a new `ObjectDetectionClient` TCA dependency with interface/live split (matching the existing `PhotoCaptureClient` pattern). The interface defines a detection mode enum (manual/auto), detection results model, and async stream of detections. The live implementation wraps the Ultralytics YOLO Swift package, running CoreML inference on camera frames. The `PhotoCaptureClientLive` actor is extended with a video data output to provide `CVPixelBuffer` frames (wrapped in a Sendable container) for detection. Frame throttling ensures only ~5fps reaches the detection pipeline, and inference runs on a dedicated non-actor queue to avoid blocking the actor. The YOLO11n INT8 CoreML model (~3 MB) is pre-compiled and bundled directly in the SPM package for offline, instant availability.

**Tech Stack:** Swift 6.2, TCA (swift-composable-architecture), Ultralytics YOLO Swift Package (`https://github.com/ultralytics/yolo-ios-app.git`), CoreML, AVFoundation

**Note on YOLO API:** The YOLO Swift package API (class names, method signatures, result properties) used in this plan is based on research and may differ from the actual package. Task 7 includes an API verification step before writing the live implementation.

---

## File Structure

```
Sources/
├── PhotoCaptureClient/
│   ├── Interface.swift              (MODIFY — add pixel buffer stream)
│   ├── Models.swift                 (MODIFY — add PixelBufferWrapper model)
│   ├── Mocks.swift                  (MODIFY — update mocks for new stream)
│   └── Extensions.swift             (no change)
│
├── PhotoCaptureClientLive/
│   ├── Live.swift                   (MODIFY — wire new stream method)
│   └── Actor.swift                  (MODIFY — add AVCaptureVideoDataOutput with throttling)
│
├── ObjectDetectionClient/
│   ├── Interface.swift              (CREATE — @DependencyClient with detect/mode/results)
│   ├── Models.swift                 (CREATE — DetectedObject, BoundingBox, DetectionResult)
│   ├── Mocks.swift                  (CREATE — DependencyValues, TestDependencyKey, noop/happy/failing)
│   └── Extensions.swift             (CREATE — Configuration convenience initializers)
│
└── ObjectDetectionClientLive/
    ├── Live.swift                   (CREATE — DependencyKey liveValue)
    ├── Actor.swift                  (CREATE — YOLO model loading from bundle, inference on dedicated queue)
    └── Resources/
        └── yolo11n.mlmodelc/        (BUNDLE — pre-compiled CoreML model, ~3 MB)

Tests/
├── PhotoCaptureClientTests/
│   └── PhotoCaptureClientTests.swift  (no change — existing tests)
│
└── ObjectDetectionClientTests/
    └── ObjectDetectionClientTests.swift  (CREATE — detection mode, results, mocks, error tests)
```

---

## Task 1: Export and Pre-Compile the YOLO CoreML Model

The YOLO Swift package does NOT auto-download models at runtime. We must provide the model ourselves. Since yolo11n INT8 is only ~3 MB, we bundle it directly in the SPM package for instant, offline availability.

**Prerequisite:** Python 3.8+ with pip.

**Files:**
- Create: `Sources/ObjectDetectionClientLive/Resources/yolo11n.mlmodelc/` (compiled model directory)

- [ ] **Step 1: Install the Ultralytics Python package**

```bash
pip install ultralytics
```

Expected: `ultralytics` package installed successfully.

- [ ] **Step 2: Export YOLO11n to CoreML format with INT8 quantization**

```bash
python3 -c "
from ultralytics import YOLO
model = YOLO('yolo11n.pt')
model.export(format='coreml', int8=True, nms=True)
print('Export complete!')
"
```

Expected: Creates `yolo11n.mlpackage` in the current directory (~3 MB). The `int8=True` flag applies INT8 quantization for optimal mobile performance. The `nms=True` flag includes Non-Maximum Suppression in the model, so post-processing is handled by CoreML.

> **Alternative:** If you don't have Python, download the pre-exported model from [Ultralytics GitHub Releases](https://github.com/ultralytics/yolo-ios-app/releases). Look for `yolo11n` INT8 CoreML model. Unzip if needed.

- [ ] **Step 3: Pre-compile the model to .mlmodelc format**

SPM does not auto-compile `.mlpackage` files. We must pre-compile to `.mlmodelc`:

```bash
mkdir -p Sources/ObjectDetectionClientLive/Resources
xcrun coremlcompiler compile yolo11n.mlpackage Sources/ObjectDetectionClientLive/Resources/
```

Expected: Creates `Sources/ObjectDetectionClientLive/Resources/yolo11n.mlmodelc/` directory containing the compiled CoreML model.

- [ ] **Step 4: Verify the compiled model exists**

```bash
ls -la Sources/ObjectDetectionClientLive/Resources/yolo11n.mlmodelc/
```

Expected: Shows compiled model files (model.mil, weights/, etc.). Total size should be ~3 MB.

- [ ] **Step 5: Clean up the .mlpackage source file**

```bash
rm -rf yolo11n.mlpackage
# Also remove the downloaded .pt file if present
rm -f yolo11n.pt
```

We only keep the pre-compiled `.mlmodelc` in the repository.

- [ ] **Step 6: Add .mlpackage and .pt to .gitignore**

Append to `.gitignore`:

```
# YOLO model source files (we only commit the compiled .mlmodelc)
*.mlpackage
*.pt
```

- [ ] **Step 7: Commit the compiled model**

```bash
git add Sources/ObjectDetectionClientLive/Resources/yolo11n.mlmodelc/
git add .gitignore
git commit -m "feat: add pre-compiled YOLO11n INT8 CoreML model (~3 MB)"
```

---

## Task 2: Add YOLO Swift Package Dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the YOLO package dependency and new targets to Package.swift**

Note the `resources` parameter on `ObjectDetectionClientLive` — this bundles the pre-compiled model.

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoCaptureClient",
    platforms: [
        .iOS(.v17), .macOS(.v14)
    ],
    products: [
        .singleTargetLibrary("PhotoCaptureClient"),
        .singleTargetLibrary("PhotoCaptureClientLive"),
        .singleTargetLibrary("ObjectDetectionClient"),
        .singleTargetLibrary("ObjectDetectionClientLive"),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-composable-architecture.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/ultralytics/yolo-ios-app.git",
            branch: "main"
        ),
    ],
    targets: [
        .target(
            name: "PhotoCaptureClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "PhotoCaptureClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "PhotoCaptureClient"
            ]
        ),
        .target(
            name: "ObjectDetectionClient",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "ObjectDetectionClientLive",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "YOLO", package: "yolo-ios-app"),
                "ObjectDetectionClient",
                "PhotoCaptureClient",
            ],
            resources: [
                .copy("Resources/yolo11n.mlmodelc"),
            ]
        ),
        .testTarget(
            name: "PhotoCaptureClientTests",
            dependencies: [
                "PhotoCaptureClient",
            ]
        ),
        .testTarget(
            name: "ObjectDetectionClientTests",
            dependencies: [
                "ObjectDetectionClient",
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
```

Key difference from the previous plan: The `ObjectDetectionClientLive` target now has `resources: [.copy("Resources/yolo11n.mlmodelc")]`. We use `.copy()` (not `.process()`) to preserve the compiled model's directory structure.

- [ ] **Step 2: Resolve dependencies and verify YOLO product exists**

Run: `swift package resolve`
Expected: Dependencies resolve successfully, YOLO package fetched.

Then verify the YOLO product is available:
Run: `swift package describe --type json | grep -A2 '"YOLO"'`
Expected: Shows `YOLO` as a library product from the yolo-ios-app package.

If the product name differs (e.g., `UltralyticsYOLO` instead of `YOLO`), update `Package.swift` accordingly.

- [ ] **Step 3: Verify existing targets still build**

Run: `swift build --target PhotoCaptureClient`
Expected: Build succeeds (existing targets unaffected).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat: add YOLO package dependency and ObjectDetection targets with bundled model"
```

---

## Task 3: Extend PhotoCaptureClient Interface with Frame Delivery

The detection system needs camera frames. We add a `pixelBufferStream` to `PhotoCaptureClient` so `ObjectDetectionClientLive` can subscribe to frames without owning the camera session.

**Key design decision:** Instead of copying raw pixel data into `Data` (which would be ~8MB per frame at 1080p, causing ~240MB/s allocation), we use a `PixelBufferWrapper` that retains the `CVPixelBuffer` reference. This follows the same `@unchecked Sendable` wrapper pattern used by `PreviewLayer`.

**Files:**
- Modify: `Sources/PhotoCaptureClient/Models.swift`
- Modify: `Sources/PhotoCaptureClient/Interface.swift`
- Modify: `Sources/PhotoCaptureClient/Mocks.swift`

- [ ] **Step 1: Add PixelBufferWrapper model to Models.swift**

Add `import CoreVideo` at the top of `Sources/PhotoCaptureClient/Models.swift`.

Then add at the end of the file:

```swift
// MARK: - PixelBufferWrapper

extension PhotoCaptureClient {
    /// A Sendable wrapper around CVPixelBuffer for crossing isolation boundaries.
    /// CVPixelBuffer is not Sendable, so this wrapper retains it and exposes metadata.
    /// Follows the same pattern as `PreviewLayer`.
    public final class PixelBufferWrapper: @unchecked Sendable {
        /// The underlying pixel buffer. Retained for the lifetime of this wrapper.
        public let pixelBuffer: CVPixelBuffer
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public let timestamp: Date

        public init(
            pixelBuffer: CVPixelBuffer,
            width: Int,
            height: Int,
            bytesPerRow: Int,
            timestamp: Date = .now
        ) {
            CVPixelBufferRetain(pixelBuffer)
            self.pixelBuffer = pixelBuffer
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            self.timestamp = timestamp
        }

        deinit {
            CVPixelBufferRelease(pixelBuffer)
        }
    }
}
```

- [ ] **Step 2: Add pixelBufferStream to Interface.swift**

Add in `Sources/PhotoCaptureClient/Interface.swift`, after the `events` property:

```swift
// MARK: - Frame Delivery

/// Stream of pixel buffers from the camera. Used by ObjectDetectionClientLive for inference.
public var pixelBufferStream: @Sendable () async -> AsyncStream<PixelBufferWrapper> = { AsyncStream { _ in } }
```

- [ ] **Step 3: Update mocks in Mocks.swift**

Update the `noop`, `happy`, and `failing` static properties to include the new `pixelBufferStream` closure. For all three mocks, add after the `events` line:

```swift
pixelBufferStream: { AsyncStream { _ in } },
```

The mocks return empty streams since we can't create real CVPixelBuffers in tests without a GPU context.

- [ ] **Step 4: Run existing tests to verify no regressions**

Run: `swift test --filter PhotoCaptureClientTests`
Expected: All 4 tests pass. The `@DependencyClient` macro provides a default empty stream for the new closure.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhotoCaptureClient/
git commit -m "feat: add PixelBufferWrapper and frame delivery stream to PhotoCaptureClient"
```

---

## Task 4: Implement Frame Delivery in PhotoCaptureClientLive

**Key design decisions:**
- **Throttling:** Only deliver ~5 frames per second to the detection pipeline using timestamp-based throttling in the delegate callback. YOLO inference typically takes 30-100ms, so 5fps is sufficient.
- **No actor hop per frame:** The delegate callback yields directly into `AsyncStream.Continuation` without creating a `Task` per frame, avoiding the overhead of ~30 unstructured tasks per second.

**Files:**
- Modify: `Sources/PhotoCaptureClientLive/Actor.swift`
- Modify: `Sources/PhotoCaptureClientLive/Live.swift`

- [ ] **Step 1: Add AVCaptureVideoDataOutput and throttling to the delegate in Actor.swift**

In `PhotoCaptureDelegate`, add these properties:

```swift
// Frame delivery properties
private(set) var videoDataOutput: AVCaptureVideoDataOutput?
private let videoDataQueue = DispatchQueue(label: "PhotoCaptureDelegate.videoDataQueue")

// Direct continuation for frame delivery — avoids actor hop per frame
var pixelBufferContinuation: AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation?

// Throttling: only deliver a frame every 200ms (~5fps)
private let frameIntervalSeconds: CFTimeInterval = 0.2
private var lastFrameTime: CFTimeInterval = 0
```

- [ ] **Step 2: Add video data output during session configuration**

In `configureSession(position:)`, after adding `photoOutput` and before `session.commitConfiguration()`, add:

```swift
// Add video data output for frame delivery
let videoOutput = AVCaptureVideoDataOutput()
videoOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
videoOutput.alwaysDiscardsLateVideoFrames = true
if session.canAddOutput(videoOutput) {
    session.addOutput(videoOutput)
    self.videoDataOutput = videoOutput
}
```

- [ ] **Step 3: Implement AVCaptureVideoDataOutputSampleBufferDelegate**

Add a new extension on `PhotoCaptureDelegate`:

```swift
// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PhotoCaptureDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Throttle: skip frames if we're delivering too fast
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= frameIntervalSeconds else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let wrapper = PhotoCaptureClient.PixelBufferWrapper(
            pixelBuffer: pixelBuffer,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            timestamp: .now
        )

        // Yield directly into the continuation — no actor hop needed
        pixelBufferContinuation?.yield(wrapper)
    }
}
```

Add `import CoreMedia` at the top of Actor.swift if not already present.

- [ ] **Step 4: Add pixel buffer stream to the actor**

In `PhotoCaptureClientActor`, add:

```swift
func observePixelBuffers() -> AsyncStream<PhotoCaptureClient.PixelBufferWrapper> {
    return AsyncStream { continuation in
        // The delegate writes directly into this continuation from the video data queue.
        // Only one subscriber is supported at a time (last subscriber wins).
        delegate.pixelBufferContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.clearPixelBufferContinuation() }
        }
    }
}

private func clearPixelBufferContinuation() {
    delegate.pixelBufferContinuation = nil
}
```

- [ ] **Step 5: Clean up in stopSession**

In `stopSession()`, add before `eventContinuations.removeAll()`:

```swift
delegate.pixelBufferContinuation?.finish()
delegate.pixelBufferContinuation = nil
```

- [ ] **Step 6: Clean up videoDataOutput in delegate teardown**

In `PhotoCaptureDelegate.teardown()`, add alongside the other nil assignments:

```swift
pixelBufferContinuation?.finish()
pixelBufferContinuation = nil
videoDataOutput = nil
```

- [ ] **Step 7: Wire pixelBufferStream in Live.swift**

In `Sources/PhotoCaptureClientLive/Live.swift`, add to the `PhotoCaptureClient(...)` initializer:

```swift
pixelBufferStream: {
    await actor.observePixelBuffers()
},
```

- [ ] **Step 8: Build to verify**

Run: `swift build --target PhotoCaptureClientLive`
Expected: Build succeeds.

- [ ] **Step 9: Run tests to verify no regressions**

Run: `swift test --filter PhotoCaptureClientTests`
Expected: All existing tests pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/PhotoCaptureClientLive/
git commit -m "feat: implement throttled frame delivery via AVCaptureVideoDataOutput"
```

---

## Task 5: Create ObjectDetectionClient Interface

**Files:**
- Create: `Sources/ObjectDetectionClient/Interface.swift`
- Create: `Sources/ObjectDetectionClient/Models.swift`
- Create: `Sources/ObjectDetectionClient/Mocks.swift` (includes DependencyValues + TestDependencyKey, matching PhotoCaptureClient pattern)
- Create: `Sources/ObjectDetectionClient/Extensions.swift` (Configuration convenience only)

- [ ] **Step 1: Create the directory**

```bash
mkdir -p Sources/ObjectDetectionClient
```

- [ ] **Step 2: Create Models.swift**

Write `Sources/ObjectDetectionClient/Models.swift`:

```swift
import Foundation

// MARK: - DetectionMode

extension ObjectDetectionClient {
    /// The detection operating mode.
    public enum DetectionMode: Sendable, Equatable {
        /// Manual mode — no object detection, camera only.
        case manual
        /// Auto mode — YOLO object detection on camera frames.
        case auto
    }
}

// MARK: - DetectedObject

extension ObjectDetectionClient {
    /// A single detected object from YOLO inference.
    public struct DetectedObject: Sendable, Equatable, Identifiable {
        public let id: UUID
        /// Class label (e.g., "person", "car", "dog").
        public let label: String
        /// Confidence score from 0.0 to 1.0.
        public let confidence: Float
        /// Normalized bounding box (0.0-1.0 coordinate space).
        public let boundingBox: BoundingBox

        public init(
            id: UUID = UUID(),
            label: String,
            confidence: Float,
            boundingBox: BoundingBox
        ) {
            self.id = id
            self.label = label
            self.confidence = confidence
            self.boundingBox = boundingBox
        }
    }
}

// MARK: - BoundingBox

extension ObjectDetectionClient {
    /// Normalized bounding box in 0.0-1.0 coordinate space.
    public struct BoundingBox: Sendable, Equatable {
        public let x: Float
        public let y: Float
        public let width: Float
        public let height: Float

        public init(x: Float, y: Float, width: Float, height: Float) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }
}

// MARK: - DetectionResult

extension ObjectDetectionClient {
    /// A single frame's detection result.
    public struct DetectionResult: Sendable, Equatable {
        /// All detected objects in this frame.
        public let objects: [DetectedObject]
        /// Inference time in milliseconds.
        public let inferenceTimeMs: Double
        /// Timestamp of the frame.
        public let timestamp: Date

        public init(
            objects: [DetectedObject] = [],
            inferenceTimeMs: Double = 0,
            timestamp: Date = .now
        ) {
            self.objects = objects
            self.inferenceTimeMs = inferenceTimeMs
            self.timestamp = timestamp
        }
    }
}

// MARK: - Configuration

extension ObjectDetectionClient {
    /// Configuration for the detection engine.
    public struct Configuration: Sendable, Equatable {
        /// Model name matching the bundled .mlmodelc resource (e.g., "yolo11n").
        public var modelName: String
        /// Minimum confidence threshold (0.0-1.0).
        public var confidenceThreshold: Float
        /// Maximum number of detections per frame.
        public var maxDetections: Int

        public init(
            modelName: String = "yolo11n",
            confidenceThreshold: Float = 0.25,
            maxDetections: Int = 20
        ) {
            self.modelName = modelName
            self.confidenceThreshold = confidenceThreshold
            self.maxDetections = maxDetections
        }
    }
}

// MARK: - Error

extension ObjectDetectionClient {
    public enum Error: Swift.Error, Sendable, LocalizedError {
        case modelLoadFailed(String)
        case inferenceFailed(String)
        case invalidMode
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let reason):
                return "Failed to load YOLO model: \(reason)"
            case .inferenceFailed(let reason):
                return "Object detection inference failed: \(reason)"
            case .invalidMode:
                return "Operation not available in current detection mode"
            case .notRunning:
                return "Object detection is not running"
            }
        }
    }
}
```

- [ ] **Step 3: Create Interface.swift**

Write `Sources/ObjectDetectionClient/Interface.swift`:

```swift
import DependenciesMacros
import Foundation

/// A dependency client for YOLO-based object detection on camera frames.
///
/// Supports two modes:
/// - `.manual` (default): No detection, camera-only operation.
/// - `.auto`: YOLO object detection runs on each camera frame.
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.objectDetection) var objectDetection
///
/// // Start auto detection (loads bundled yolo11n model)
/// try await objectDetection.startDetection(.default)
///
/// // Observe results
/// for await result in await objectDetection.detectionResults() {
///     print("Detected \(result.objects.count) objects")
/// }
/// ```
@DependencyClient
public struct ObjectDetectionClient: Sendable {

    // MARK: - Mode Control

    /// The current detection mode.
    public var currentMode: @Sendable () -> DetectionMode = { .manual }

    /// Switch to auto mode: loads the YOLO model and begins detection.
    public var startDetection: @Sendable (_ configuration: Configuration) async throws -> Void

    /// Switch to manual mode: stops detection and unloads the model.
    public var stopDetection: @Sendable () async -> Void = { }

    // MARK: - Detection Results

    /// Stream of detection results (only emits in auto mode).
    public var detectionResults: @Sendable () async -> AsyncStream<DetectionResult> = { AsyncStream { _ in } }

    // MARK: - Single Image Detection

    /// Run detection on a single image (Data = JPEG/PNG bytes). Works regardless of mode.
    public var detectInImage: @Sendable (_ imageData: Data) async throws -> DetectionResult
}
```

- [ ] **Step 4: Create Mocks.swift (includes DependencyValues + TestDependencyKey)**

Write `Sources/ObjectDetectionClient/Mocks.swift`:

```swift
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
```

- [ ] **Step 5: Create Extensions.swift (convenience initializers only)**

Write `Sources/ObjectDetectionClient/Extensions.swift`:

```swift
import Foundation

// MARK: - Configuration Convenience

extension ObjectDetectionClient.Configuration {
    /// Default configuration using the bundled YOLO11n model.
    public static let `default` = Self()

    /// High accuracy configuration with lower confidence threshold.
    public static let highAccuracy = Self(
        modelName: "yolo11n",
        confidenceThreshold: 0.1,
        maxDetections: 50
    )

    /// Fast configuration with higher confidence threshold for fewer, more confident detections.
    public static let fast = Self(
        modelName: "yolo11n",
        confidenceThreshold: 0.5,
        maxDetections: 10
    )
}
```

- [ ] **Step 6: Build the ObjectDetectionClient target**

Run: `swift build --target ObjectDetectionClient`
Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Sources/ObjectDetectionClient/
git commit -m "feat: add ObjectDetectionClient interface with models and mocks"
```

---

## Task 6: Write ObjectDetectionClient Tests

**Files:**
- Create: `Tests/ObjectDetectionClientTests/ObjectDetectionClientTests.swift`

- [ ] **Step 1: Create the test directory**

```bash
mkdir -p Tests/ObjectDetectionClientTests
```

- [ ] **Step 2: Write tests**

Write `Tests/ObjectDetectionClientTests/ObjectDetectionClientTests.swift`:

```swift
import Dependencies
import XCTest
@testable import ObjectDetectionClient

final class ObjectDetectionClientTests: XCTestCase {
    func testDefaultModeIsManual() {
        withDependencies {
            $0.objectDetection = .noop
        } operation: {
            @Dependency(\.objectDetection) var client
            XCTAssertEqual(client.currentMode(), .manual)
        }
    }

    func testHappyPathStartDetection() async throws {
        try await withDependencies {
            $0.objectDetection = .happy
        } operation: {
            @Dependency(\.objectDetection) var client

            XCTAssertEqual(client.currentMode(), .auto)
            try await client.startDetection(.default)
        }
    }

    func testHappyPathDetectInImage() async throws {
        try await withDependencies {
            $0.objectDetection = .happy
        } operation: {
            @Dependency(\.objectDetection) var client

            let result = try await client.detectInImage(Data())
            XCTAssertFalse(result.objects.isEmpty)
            XCTAssertEqual(result.objects.first?.label, "cat")
            XCTAssertGreaterThan(result.objects.first?.confidence ?? 0, 0.9)
        }
    }

    func testNoopPath() async throws {
        try await withDependencies {
            $0.objectDetection = .noop
        } operation: {
            @Dependency(\.objectDetection) var client

            XCTAssertEqual(client.currentMode(), .manual)
            try await client.startDetection(.default)
            let result = try await client.detectInImage(Data())
            XCTAssertTrue(result.objects.isEmpty)
            await client.stopDetection()
        }
    }

    func testFailingPathStartDetection() async {
        await withDependencies {
            $0.objectDetection = .failing
        } operation: {
            @Dependency(\.objectDetection) var client

            do {
                try await client.startDetection(.default)
                XCTFail("Expected error")
            } catch {
                XCTAssertTrue(error is ObjectDetectionClient.Error)
            }
        }
    }

    func testFailingPathDetectInImage() async {
        await withDependencies {
            $0.objectDetection = .failing
        } operation: {
            @Dependency(\.objectDetection) var client

            do {
                _ = try await client.detectInImage(Data())
                XCTFail("Expected error")
            } catch {
                XCTAssertTrue(error is ObjectDetectionClient.Error)
            }
        }
    }

    func testConfigurationConvenience() {
        let defaultConfig = ObjectDetectionClient.Configuration.default
        XCTAssertEqual(defaultConfig.modelName, "yolo11n")
        XCTAssertEqual(defaultConfig.confidenceThreshold, 0.25)
        XCTAssertEqual(defaultConfig.maxDetections, 20)

        let fast = ObjectDetectionClient.Configuration.fast
        XCTAssertEqual(fast.confidenceThreshold, 0.5)
        XCTAssertEqual(fast.maxDetections, 10)

        let highAccuracy = ObjectDetectionClient.Configuration.highAccuracy
        XCTAssertEqual(highAccuracy.confidenceThreshold, 0.1)
        XCTAssertEqual(highAccuracy.maxDetections, 50)
    }

    func testDetectedObjectIdentifiable() {
        let id = UUID()
        let obj = ObjectDetectionClient.DetectedObject(
            id: id,
            label: "person",
            confidence: 0.9,
            boundingBox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
        XCTAssertEqual(obj.id, id)
    }

    func testBoundingBoxValues() {
        let box = ObjectDetectionClient.BoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(box.x, 0.1)
        XCTAssertEqual(box.y, 0.2)
        XCTAssertEqual(box.width, 0.3)
        XCTAssertEqual(box.height, 0.4)
    }

    func testErrorDescriptions() {
        let modelError = ObjectDetectionClient.Error.modelLoadFailed("not found")
        XCTAssertEqual(modelError.errorDescription, "Failed to load YOLO model: not found")

        let inferenceError = ObjectDetectionClient.Error.inferenceFailed("timeout")
        XCTAssertEqual(inferenceError.errorDescription, "Object detection inference failed: timeout")

        let modeError = ObjectDetectionClient.Error.invalidMode
        XCTAssertEqual(modeError.errorDescription, "Operation not available in current detection mode")

        let notRunning = ObjectDetectionClient.Error.notRunning
        XCTAssertEqual(notRunning.errorDescription, "Object detection is not running")
    }

    func testDetectionResultEquality() {
        let obj = ObjectDetectionClient.DetectedObject(
            label: "person",
            confidence: 0.9,
            boundingBox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )

        let result1 = ObjectDetectionClient.DetectionResult(objects: [obj])
        let result2 = ObjectDetectionClient.DetectionResult(objects: [obj])
        XCTAssertEqual(result1.objects, result2.objects)
    }
}
```

- [ ] **Step 3: Run the tests**

Run: `swift test --filter ObjectDetectionClientTests`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/ObjectDetectionClientTests/
git commit -m "test: add ObjectDetectionClient unit tests"
```

---

## Task 7: Verify YOLO Package API and Implement ObjectDetectionClientLive

> **Important:** Before writing the live implementation, we must verify the actual YOLO Swift package API. The code below is based on research and WILL need adaptation.

**Files:**
- Create: `Sources/ObjectDetectionClientLive/Actor.swift`
- Create: `Sources/ObjectDetectionClientLive/Live.swift`

- [ ] **Step 1: Create the directory (if not already created by Task 1)**

```bash
mkdir -p Sources/ObjectDetectionClientLive
```

- [ ] **Step 2: Verify the YOLO package API**

After `swift package resolve` (done in Task 2), inspect the actual YOLO source:

```bash
# Find the YOLO package source files
find .build -path "*/yolo-ios-app/Sources/YOLO" -name "*.swift" 2>/dev/null | head -20
```

Read the key files and verify:

1. **Model initializer:** Is it `YOLO("yolo11n")` or `YOLO(modelPathOrName: "yolo11n")`? Does it accept a file URL to a `.mlmodelc`?
2. **Loading from URL:** Can the YOLO class load a model from a specific file URL? (We need this to load from `Bundle.module`)
3. **Inference method:** Is it `callAsFunction(UIImage)` that throws? Or a different method? Does it accept `CIImage` or `CVPixelBuffer` directly?
4. **Result type:** What is the return type? `YOLOResult`? What properties does it have?
5. **Box properties:** What are the property names for class label, confidence, and bounding box coordinates?

Document the actual API before proceeding. Adapt the code in Step 3 accordingly.

- [ ] **Step 3: Create Actor.swift — the YOLO inference actor**

**Key design decisions:**
- **Bundled model loading:** The model is loaded from `Bundle.module` using the pre-compiled `.mlmodelc` resource. No network download needed.
- **Thread-safe mode:** Use `OSAllocatedUnfairLock` to store the detection mode outside the actor, allowing `currentMode()` to be called synchronously without actor hopping.
- **Non-blocking inference:** YOLO inference runs on a dedicated `DispatchQueue`, not inside the actor, so the actor remains responsive to `stopDetection()` and `observeResults()` calls.
- **Cached CIContext:** A single `CIContext` is reused across frames to avoid expensive per-frame allocation.

Write `Sources/ObjectDetectionClientLive/Actor.swift`:

```swift
import Foundation
import ObjectDetectionClient
import PhotoCaptureClient
import YOLO
import os
#if canImport(UIKit)
import UIKit
#endif

/// Actor that manages YOLO model lifecycle and runs inference on camera frames.
/// The model is loaded from the pre-compiled .mlmodelc bundled in this SPM target's resources.
actor ObjectDetectionClientActor {
    private var model: YOLO?
    private var configuration: ObjectDetectionClient.Configuration?
    private var resultContinuations: [UUID: AsyncStream<ObjectDetectionClient.DetectionResult>.Continuation] = [:]
    private var frameProcessingTask: Task<Void, Never>?

    /// Thread-safe mode accessible from any isolation domain.
    private let modeStorage = OSAllocatedUnfairLock(initialState: ObjectDetectionClient.DetectionMode.manual)

    /// Dedicated queue for YOLO inference — keeps the actor unblocked.
    private let inferenceQueue = DispatchQueue(label: "ObjectDetectionClientActor.inference", qos: .userInitiated)

    /// Cached CIContext for pixel buffer → CGImage conversion. Reused across frames.
    #if canImport(UIKit)
    private let ciContext = CIContext()
    #endif

    private let logger: @Sendable (String) -> Void

    init(
        logger: @escaping @Sendable (String) -> Void = { message in
            #if DEBUG
            print("[OBJECT_DETECTION]: \(message)")
            #endif
        }
    ) {
        self.logger = logger
    }

    // MARK: - Mode

    /// Thread-safe, nonisolated access to current detection mode.
    nonisolated func currentMode() -> ObjectDetectionClient.DetectionMode {
        modeStorage.withLock { $0 }
    }

    // MARK: - Model Loading

    /// Resolves the bundled .mlmodelc URL from Bundle.module.
    private func bundledModelURL(name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "mlmodelc")
    }

    // MARK: - Start / Stop

    func startDetection(
        configuration: ObjectDetectionClient.Configuration,
        pixelBufferStream: @Sendable () async -> AsyncStream<PhotoCaptureClient.PixelBufferWrapper>
    ) async throws {
        guard currentMode() == .manual else {
            logger("Detection already running")
            return
        }

        logger("Loading YOLO model: \(configuration.modelName)")
        self.configuration = configuration

        // Load model from bundled .mlmodelc resource.
        // NOTE: Adapt the initializer below based on Step 2 API verification.
        // The YOLO class may accept a URL, a file path string, or a model name.
        // Possible patterns:
        //   - YOLO(modelPathOrName: url.path)
        //   - YOLO(url.path)
        //   - YOLO(configuration.modelName)  // if it searches Bundle.main
        guard let modelURL = bundledModelURL(name: configuration.modelName) else {
            throw ObjectDetectionClient.Error.modelLoadFailed(
                "Bundled model '\(configuration.modelName).mlmodelc' not found in resources"
            )
        }

        do {
            let yolo = try YOLO(modelURL.path)
            self.model = yolo
            logger("YOLO model loaded from bundle: \(modelURL.path)")
        } catch {
            throw ObjectDetectionClient.Error.modelLoadFailed(error.localizedDescription)
        }

        modeStorage.withLock { $0 = .auto }

        // Start processing frames
        frameProcessingTask = Task { [weak self] in
            let stream = await pixelBufferStream()
            for await wrapper in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.processFrame(wrapper)
            }
        }
    }

    func stopDetection() {
        logger("Stopping detection")
        frameProcessingTask?.cancel()
        frameProcessingTask = nil
        modeStorage.withLock { $0 = .manual }
        model = nil
        configuration = nil

        for continuation in resultContinuations.values {
            continuation.finish()
        }
        resultContinuations.removeAll()
    }

    // MARK: - Frame Processing

    private func processFrame(_ wrapper: PhotoCaptureClient.PixelBufferWrapper) async {
        guard let model else { return }
        guard let configuration else { return }

        // Offload inference to a dedicated queue to avoid blocking the actor.
        let result: ObjectDetectionClient.DetectionResult? = await withCheckedContinuation { continuation in
            inferenceQueue.async { [ciContext = self.ciContext] in
                let start = CFAbsoluteTimeGetCurrent()

                #if canImport(UIKit)
                // Create CIImage from the retained CVPixelBuffer — no data copy needed.
                let ciImage = CIImage(cvPixelBuffer: wrapper.pixelBuffer)

                guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                    continuation.resume(returning: nil)
                    return
                }

                let uiImage = UIImage(cgImage: cgImage)

                do {
                    // NOTE: Adapt the call below based on Step 2 API verification.
                    let yoloResult = try model(uiImage)
                    let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000

                    var detectedObjects: [ObjectDetectionClient.DetectedObject] = []

                    // NOTE: Adapt property names below based on Step 2 API verification.
                    // .boxes, .cls, .confidence, .xywhn may differ in the actual package.
                    for box in yoloResult.boxes.prefix(configuration.maxDetections) {
                        guard box.confidence >= configuration.confidenceThreshold else { continue }

                        let boundingBox = ObjectDetectionClient.BoundingBox(
                            x: Float(box.xywhn.origin.x),
                            y: Float(box.xywhn.origin.y),
                            width: Float(box.xywhn.size.width),
                            height: Float(box.xywhn.size.height)
                        )

                        detectedObjects.append(ObjectDetectionClient.DetectedObject(
                            label: box.cls,
                            confidence: box.confidence,
                            boundingBox: boundingBox
                        ))
                    }

                    let result = ObjectDetectionClient.DetectionResult(
                        objects: detectedObjects,
                        inferenceTimeMs: inferenceTime,
                        timestamp: wrapper.timestamp
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(returning: nil)
                }
                #else
                continuation.resume(returning: nil)
                #endif
            }
        }

        if let result {
            yieldResult(result)
        }
    }

    // MARK: - Single Image Detection

    func detectInImage(_ imageData: Data) async throws -> ObjectDetectionClient.DetectionResult {
        #if canImport(UIKit)
        // Use existing model if loaded, otherwise load from bundle on-demand.
        let yolo: YOLO
        if let existingModel = model {
            yolo = existingModel
        } else {
            let modelName = configuration?.modelName ?? "yolo11n"
            guard let modelURL = bundledModelURL(name: modelName) else {
                throw ObjectDetectionClient.Error.modelLoadFailed(
                    "Bundled model '\(modelName).mlmodelc' not found in resources"
                )
            }
            do {
                yolo = try YOLO(modelURL.path)
            } catch {
                throw ObjectDetectionClient.Error.modelLoadFailed(error.localizedDescription)
            }
        }

        guard let uiImage = UIImage(data: imageData) else {
            throw ObjectDetectionClient.Error.inferenceFailed("Invalid image data")
        }

        let start = CFAbsoluteTimeGetCurrent()

        do {
            // NOTE: Adapt based on Step 2 API verification.
            let yoloResult = try yolo(uiImage)
            let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let config = configuration ?? .default

            var detectedObjects: [ObjectDetectionClient.DetectedObject] = []

            for box in yoloResult.boxes.prefix(config.maxDetections) {
                guard box.confidence >= config.confidenceThreshold else { continue }

                let boundingBox = ObjectDetectionClient.BoundingBox(
                    x: Float(box.xywhn.origin.x),
                    y: Float(box.xywhn.origin.y),
                    width: Float(box.xywhn.size.width),
                    height: Float(box.xywhn.size.height)
                )

                detectedObjects.append(ObjectDetectionClient.DetectedObject(
                    label: box.cls,
                    confidence: box.confidence,
                    boundingBox: boundingBox
                ))
            }

            return ObjectDetectionClient.DetectionResult(
                objects: detectedObjects,
                inferenceTimeMs: inferenceTime,
                timestamp: .now
            )
        } catch {
            throw ObjectDetectionClient.Error.inferenceFailed(error.localizedDescription)
        }
        #else
        throw ObjectDetectionClient.Error.inferenceFailed("Object detection requires iOS")
        #endif
    }

    // MARK: - Streams

    func observeResults() -> AsyncStream<ObjectDetectionClient.DetectionResult> {
        let id = UUID()
        return AsyncStream { continuation in
            resultContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        resultContinuations.removeValue(forKey: id)
    }

    private func yieldResult(_ result: ObjectDetectionClient.DetectionResult) {
        for continuation in resultContinuations.values {
            continuation.yield(result)
        }
    }
}
```

- [ ] **Step 4: Create Live.swift — DependencyKey registration**

Write `Sources/ObjectDetectionClientLive/Live.swift`:

```swift
import ComposableArchitecture
import ObjectDetectionClient
import PhotoCaptureClient

/// Note: ObjectDetectionClientLive has a runtime coupling to PhotoCaptureClient.
/// When `startDetection` is called, it resolves `@Dependency(\.photoCapture)` from the
/// current dependency context to access the pixel buffer stream. In tests, this means
/// PhotoCaptureClient must also be overridden if ObjectDetectionClientLive is used directly.
/// In practice, consumers should use the ObjectDetectionClient interface with mocks.
extension ObjectDetectionClient: DependencyKey {
    public static let liveValue: ObjectDetectionClient = {
        let actor = ObjectDetectionClientActor()

        return ObjectDetectionClient(
            currentMode: {
                actor.currentMode()
            },
            startDetection: { configuration in
                @Dependency(\.photoCapture) var photoCapture
                try await actor.startDetection(
                    configuration: configuration,
                    pixelBufferStream: photoCapture.pixelBufferStream
                )
            },
            stopDetection: {
                await actor.stopDetection()
            },
            detectionResults: {
                await actor.observeResults()
            },
            detectInImage: { imageData in
                try await actor.detectInImage(imageData)
            }
        )
    }()
}
```

- [ ] **Step 5: Build the ObjectDetectionClientLive target**

Run: `swift build --target ObjectDetectionClientLive`
Expected: Build succeeds. The bundled `yolo11n.mlmodelc` should be included via `Bundle.module`.

If the build fails due to YOLO API mismatches, go back to Step 2 and read the actual YOLO source, then adapt `Actor.swift` accordingly.

- [ ] **Step 6: Commit**

```bash
git add Sources/ObjectDetectionClientLive/
git commit -m "feat: implement ObjectDetectionClientLive with bundled YOLO model"
```

---

## Task 8: Integration Verification & Cleanup

**Files:**
- All targets

- [ ] **Step 1: Build all targets**

Run: `swift build`
Expected: All targets compile successfully.

- [ ] **Step 2: Run all tests**

Run: `swift test`
Expected: All tests pass (PhotoCaptureClientTests + ObjectDetectionClientTests).

- [ ] **Step 3: Verify the YOLO package resolves correctly**

Run: `swift package show-dependencies`
Expected: Shows `yolo-ios-app` in the dependency tree alongside `swift-composable-architecture`.

- [ ] **Step 4: Verify the bundled model is included**

```bash
# Check that the model resource is copied into the build
find .build -name "yolo11n.mlmodelc" -type d 2>/dev/null | head -5
```

Expected: Shows the compiled model directory in the build artifacts.

- [ ] **Step 5: Commit final state**

```bash
git add -A
git commit -m "chore: verify full build and test pass with YOLO integration"
```

---

## Summary of Consumer Usage

After implementation, consumers use the two clients together:

```swift
// In a TCA Reducer
@Dependency(\.photoCapture) var photoCapture
@Dependency(\.objectDetection) var objectDetection

// Manual mode (default) — just camera, no detection
try await photoCapture.startSession()
let photo = try await photoCapture.capturePhoto(.default)

// Switch to auto mode — loads bundled yolo11n model and starts detection
try await objectDetection.startDetection(.default)
for await result in await objectDetection.detectionResults() {
    // result.objects contains [DetectedObject] with labels, confidence, bounding boxes
}

// Single image detection (works in any mode, loads model on-demand from bundle)
let result = try await objectDetection.detectInImage(jpegData)

// Switch back to manual
await objectDetection.stopDetection()
```

## Architecture Notes

- **Bundled model:** The YOLO11n INT8 CoreML model (~3 MB) is pre-compiled to `.mlmodelc` and bundled in `ObjectDetectionClientLive` via SPM's `.copy()` resource rule. Loaded from `Bundle.module` — no network download required, works offline.
- **Model export workflow:** Export from Python (`ultralytics` package) → compile with `xcrun coremlcompiler` → commit `.mlmodelc` to repo. To update the model, repeat this process.
- **Why bundle vs download:** At ~3 MB, the model is smaller than most image assets. Bundling avoids first-use delay, network dependency, and hosting infrastructure. For larger models (yolo11m at ~39 MB), consider Apple Background Assets or GitHub Releases hosting.
- **Frame delivery performance:** `PixelBufferWrapper` retains `CVPixelBuffer` by reference (~zero-cost), not by copying pixel data. Throttled to ~5fps at the delegate level.
- **Non-blocking inference:** YOLO inference runs on a dedicated `DispatchQueue`, keeping the actor responsive to stop/observe calls. `CIContext` is cached and reused across frames.
- **Thread-safe mode:** `OSAllocatedUnfairLock` provides synchronous, nonisolated `currentMode()` access.
- **Runtime coupling:** `ObjectDetectionClientLive` resolves `PhotoCaptureClient` via `@Dependency` at call time. This is invisible at the type level — consumers should use mock interfaces in tests.
- **YOLO API adaptation:** The YOLO API in Task 7 is based on research. Task 7 Step 2 requires reading the actual package source and adapting the code before building.
