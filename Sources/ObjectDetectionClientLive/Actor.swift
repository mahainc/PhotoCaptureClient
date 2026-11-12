import CoreImage
import CoreML
import CoreVideo
import Foundation
import ObjectDetectionClient
import ObjectTracking
import PhotoCaptureClient
import Vision
import os

#if canImport(UIKit)
    import UIKit
#endif

/// Actor that manages YOLO model lifecycle and runs inference on camera frames.
/// Uses Vision framework directly (instead of YOLO library's model loading) to control
/// MLModelConfiguration.computeUnits and avoid Neural Engine MLIR crashes.
actor ObjectDetectionClientActor {
    var vnModel: VNCoreMLModel?
    var labels: [String] = []
    var configuration: ObjectDetectionClient.Configuration?
    var resultContinuations: [UUID: AsyncStream<ObjectDetectionClient.DetectionResult>.Continuation] = [:]
    /// Tracks already cropped, so each object is cut out once however long it stays.
    ///
    /// Pruned against the live track ids every frame rather than grown forever: a long
    /// session over a busy scene mints tracks continuously, and this would otherwise
    /// retain a UUID for every object the camera ever saw.
    var croppedTrackIDs: Set<UUID> = []
    var frameProcessingTask: Task<Void, Never>?

    /// Track-by-detection layer: turns identity-less per-frame detections into stable, coasted tracks.
    /// Created in `startDetection`, reset in `stopDetection`.
    var tracker: MultiObjectTracker?
    /// Timestamp of the previous processed frame, for the tracker's inter-frame `dt`.
    var lastFrameTimestamp: Date?
    /// Estimates global camera motion between frames for BoT-SORT CMC. Created in `startDetection`.
    var motionEstimator: CameraMotionEstimator?
    /// Previous processed frame, registered against the current one to estimate camera motion.
    var previousFrameWrapper: PhotoCaptureClient.PixelBufferWrapper?

    /// Monocular depth fallback for devices with no hardware depth sensor. The estimate refreshes
    /// in the background every `Self.monocularDepthInterval` frames and is cached here between
    /// refreshes; nil until the first estimate lands (ranking falls back to centre-proximity until
    /// then). Never touched on a device that delivers hardware depth — the model stays unloaded.
    let depthEstimator = DepthEstimator()
    var monocularDepth: CVPixelBuffer?
    var monocularDepthFrameCounter = 0
    /// Refresh the monocular estimate every Nth processed frame — a second full-frame inference, too
    /// costly to run every frame, and depth ranking tolerates a few frames of staleness.
    static let monocularDepthInterval = 3

    /// Thread-safe mode accessible from any isolation domain.
    let modeStorage = OSAllocatedUnfairLock(initialState: ObjectDetectionClient.DetectionMode.manual)

    /// Dedicated queue for YOLO inference — keeps the actor unblocked.
    let inferenceQueue = DispatchQueue(label: "ObjectDetectionClientActor.inference", qos: .userInitiated)

    let logger: @Sendable (String) -> Void

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

    nonisolated func currentMode() -> ObjectDetectionClient.DetectionMode {
        modeStorage.withLock { $0 }
    }
}
