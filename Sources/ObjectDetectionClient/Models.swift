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
        /// Metric depth in metres sampled at the object centre (smaller = nearer). `nil` when the
        /// capture device delivers no depth (single-camera devices, simulator) — consumers then fall
        /// back to centre-proximity for "nearest object" ranking.
        public let depth: Float?

        public init(
            id: UUID = UUID(),
            label: String,
            confidence: Float,
            boundingBox: BoundingBox,
            depth: Float? = nil
        ) {
            self.id = id
            self.label = label
            self.confidence = confidence
            self.boundingBox = boundingBox
            self.depth = depth
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

        public init(
            x: Float,
            y: Float,
            width: Float,
            height: Float
        ) {
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
        /// Low detection floor (0.0-1.0): the model emits boxes at/above this. Kept low so the
        /// tracker's ByteTrack second stage can recover momentarily low-confidence boxes.
        public var confidenceThreshold: Float
        /// High confidence (0.0-1.0): the tracker uses it for first-stage matching and to start new
        /// tracks; single-image detection filters by it.
        public var highConfidenceThreshold: Float
        /// IoU threshold for non-maximum suppression (0.0-1.0).
        public var iouThreshold: Float
        /// Maximum number of detections per frame.
        public var maxDetections: Int

        public init(
            modelName: String = "yolo11n",
            confidenceThreshold: Float = 0.25,
            highConfidenceThreshold: Float = 0.6,
            iouThreshold: Float = 0.45,
            maxDetections: Int = 10
        ) {
            self.modelName = modelName
            self.confidenceThreshold = confidenceThreshold
            self.highConfidenceThreshold = highConfidenceThreshold
            self.iouThreshold = iouThreshold
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
