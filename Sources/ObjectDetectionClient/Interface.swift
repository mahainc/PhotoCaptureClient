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
