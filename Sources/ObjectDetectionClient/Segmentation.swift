import Foundation

// MARK: - SegmentedObject

extension ObjectDetectionClient {
    /// A detected object with a pixel-accurate cutout of the subject, background removed.
    public struct SegmentedObject: Sendable, Equatable, Identifiable {
        public let id: UUID
        /// Class label (e.g., "person", "car", "dog").
        public let label: String
        /// Confidence score from 0.0 to 1.0.
        public let confidence: Float
        /// Normalized bounding box (0.0-1.0) of the subject in the source image.
        public let boundingBox: BoundingBox
        /// PNG bytes of the subject cut out of the source image: the instance mask is applied
        /// as alpha, so everything outside the subject is transparent.
        public let cutoutPNG: Data

        public init(
            id: UUID = UUID(),
            label: String,
            confidence: Float,
            boundingBox: BoundingBox,
            cutoutPNG: Data
        ) {
            self.id = id
            self.label = label
            self.confidence = confidence
            self.boundingBox = boundingBox
            self.cutoutPNG = cutoutPNG
        }
    }
}

// MARK: - SegmentationResult

extension ObjectDetectionClient {
    /// A single image's segmentation result.
    public struct SegmentationResult: Sendable, Equatable {
        /// All segmented objects, ordered by descending confidence.
        public let objects: [SegmentedObject]
        /// Inference time in milliseconds.
        public let inferenceTimeMs: Double
        /// Timestamp of the result.
        public let timestamp: Date

        public init(
            objects: [SegmentedObject] = [],
            inferenceTimeMs: Double = 0,
            timestamp: Date = .now
        ) {
            self.objects = objects
            self.inferenceTimeMs = inferenceTimeMs
            self.timestamp = timestamp
        }
    }
}
