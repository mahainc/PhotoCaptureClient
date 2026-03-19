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
