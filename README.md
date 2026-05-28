# PhotoCaptureClient

A multi-family TCA dependency client wrapping AVFoundation capture, on-device YOLO object detection, and multi-camera composition on iOS. One Swift package shipping three sibling client families:

**Photo capture family**
- **`PhotoCaptureClient`** — interface for single-camera capture: session lifecycle, photo capture, camera switching, flash, focus, zoom (incl. visual / pinch-anchored zoom).
- **`PhotoCaptureClientLive`** — `AVFoundation` wrapper with a Metal-backed preview compositor (`Shaders.metal`), registers the live `DependencyKey`.

**Object detection family**
- **`ObjectDetectionClient`** — interface for on-device detection: start / stop, result `AsyncStream<DetectionResult>`, single-image detection.
- **`ObjectDetectionClientLive`** — `YOLO` (Ultralytics) wrapper bundling the `yolo11n.mlpackage` Core ML model.

**Multi-cam family**
- **`MultiCamClient`** — interface for `AVCaptureMultiCamSession`-driven layouts (grid, PiP), per-camera zoom and stabilization.
- **`MultiCamClientLive`** — `AVFoundation` + Metal wrapper handling capture-graph wiring and PiP gesture coordination.

## Installation

In your `Package.swift`:

```swift
.package(url: "https://github.com/mahainc/PhotoCaptureClient.git", from: "0.1.0"),
```

Add the products you need:
- Interfaces (`PhotoCaptureClient`, `ObjectDetectionClient`, `MultiCamClient`) on feature targets.
- Live products on app targets.

## Usage — single-camera capture

```swift
import PhotoCaptureClient
import ComposableArchitecture

@Reducer
struct CameraFeature {
    @ObservableState
    struct State {
        var lastPhoto: Photo?
    }

    enum Action {
        case onAppear
        case onDisappear
        case capturePressed
        case photoCaptured(Photo)
    }

    @Dependency(\.photoCaptureClient) var camera

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { _ in try await camera.startSession() }

            case .onDisappear:
                return .run { _ in await camera.stopSession() }

            case .capturePressed:
                return .run { send in
                    let photo = try await camera.capturePhoto(settings: .default)
                    await send(.photoCaptured(photo))
                }

            case .photoCaptured(let photo):
                state.lastPhoto = photo
                return .none
            }
        }
    }
}
```

## Usage — object detection

```swift
import ObjectDetectionClient

@Dependency(\.objectDetectionClient) var detector

// Start streaming detections
try await detector.startDetection(configuration: .yolo11n)
for await result in await detector.detectionResults() {
    // result.boxes, result.labels, result.confidences
}
```

## Usage — multi-cam

```swift
import MultiCamClient

@Dependency(\.multiCamClient) var multiCam

let capability = multiCam.deviceCapability()
guard capability.supportsMultiCam else { /* fall back */ }

try await multiCam.startSession(configuration: .frontAndBack)
await multiCam.setLayout(.pip(.init(primary: .back, secondary: .front)))
```

## Testing

The interface modules expose unimplemented `testValue` defaults via `@DependencyClient`:

```swift
let store = TestStore(initialState: CameraFeature.State()) {
    CameraFeature()
} withDependencies: {
    $0.photoCaptureClient.startSession = { }
    $0.photoCaptureClient.capturePhoto = { _ in .preview }
}
```

## Dependencies

- `swift-composable-architecture` from 1.25.5
- `yolo-ios-app` (Ultralytics YOLO) from 1.0.0   *(ObjectDetectionClientLive only, iOS-conditional)*

## Platform support

- iOS 17+
- macOS 14+ (compiles, but capture / detection / multi-cam Live calls are iOS-conditional or no-ops)

## License

MIT — see [LICENSE](./LICENSE).
