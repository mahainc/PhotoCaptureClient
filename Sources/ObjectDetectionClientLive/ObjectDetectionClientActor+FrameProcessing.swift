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

// MARK: - Frame Processing

extension ObjectDetectionClientActor {
    func processFrame(_ wrapper: PhotoCaptureClient.PixelBufferWrapper) async {
        guard let vnModel else { return }
        guard let configuration else { return }
        guard let motionEstimator else { return }

        refreshMonocularDepthIfNeeded(for: wrapper)
        let effectiveDepth = (wrapper.depthBuffer ?? monocularDepth).map(DepthMap.init)

        let raw = await runInference(
            wrapper: wrapper,
            previousWrapper: previousFrameWrapper,
            vnModel: vnModel,
            configuration: configuration,
            motionEstimator: motionEstimator,
            depthBuffer: effectiveDepth
        )
        guard let raw else { return }

        // Tracker step runs in the actor's (single-threaded) isolation: assign stable IDs and coast
        // confirmed tracks through brief detection dropouts so the dot stops flickering/teleporting.
        let previousTimestamp = lastFrameTimestamp
        let dt = previousTimestamp.map { Float(wrapper.timestamp.timeIntervalSince($0)) } ?? 0.333
        // Never regress the stored timestamp if a frame arrives out of order, so the next dt can't
        // become a large "catch-up" value (the tracker also clamps dt to [minDt, maxDt]).
        lastFrameTimestamp = previousTimestamp.map { max($0, wrapper.timestamp) } ?? wrapper.timestamp
        previousFrameWrapper = wrapper
        let tracks = tracker?.update(detections: raw.detections, dt: dt, cameraMotion: raw.cameraMotion) ?? []
        let objects = tracks.map { track in
            ObjectDetectionClient.DetectedObject(
                id: track.id,
                label: track.label,
                confidence: track.confidence,
                boundingBox: ObjectDetectionClient.BoundingBox(
                    x: track.box.x,
                    y: track.box.y,
                    width: track.box.width,
                    height: track.box.height
                ),
                depth: track.depth,
                trackedSeconds: TimeInterval(track.trackedSeconds)
            )
        }

        // Forget tracks the tracker has retired, so the set stays the size of the scene
        // rather than the size of the session.
        croppedTrackIDs.formIntersection(tracks.map(\.id))
        let matured = await cropMaturedObjects(
            tracks: tracks,
            wrapper: wrapper,
            dwellSeconds: configuration.dwellSeconds
        )

        #if DEBUG
            // Per-frame depth diagnostic: builds a summary string and writes to the on-device log, so it
            // stays out of release builds — the string formatting and file I/O are hot-path work at the
            // detection cadence, not something a shipped app should pay for.
            if !objects.isEmpty {
                let source =
                    wrapper.depthBuffer != nil
                    ? "hardware" : (monocularDepth != nil ? "monocular" : "none")
                let summary = objects.map { object in
                    let box = object.boundingBox
                    let geometry = String(
                        format: "c=%.2f,%.2f wh=%.2fx%.2f",
                        box.x + box.width * 0.5,
                        box.y + box.height * 0.5,
                        box.width,
                        box.height
                    )
                    let depthText = object.depth.map { String(format: "%.3f", $0) } ?? "nil"
                    return
                        "\(object.label)[conf=\(String(format: "%.2f", object.confidence)) \(geometry) d=\(depthText)]"
                }
                .joined(separator: " ")
                let nearest =
                    objects
                    .compactMap { object in object.depth.map { (object.label, $0) } }
                    .min { $0.1 < $1.1 }?.0 ?? "—"
                DiagnosticLog.shared.log("DEPTH src=\(source) \(summary) → nearest=\(nearest)")
            }
        #endif

        yieldResult(
            ObjectDetectionClient.DetectionResult(
                objects: objects,
                maturedObjects: matured,
                inferenceTimeMs: raw.inferenceMs,
                timestamp: wrapper.timestamp
            )
        )
    }

    /// Cut out every track that has just crossed the dwell threshold.
    ///
    /// Runs off the actor, on the inference queue: a JPEG encode is long enough that doing
    /// it under actor isolation would hold up the next frame's detection.
    private func cropMaturedObjects(
        tracks: [Track],
        wrapper: PhotoCaptureClient.PixelBufferWrapper,
        dwellSeconds: TimeInterval?
    ) async -> [ObjectDetectionClient.MaturedObject] {
        guard let dwellSeconds else { return [] }

        let ripe = tracks.filter { track in
            TimeInterval(track.trackedSeconds) >= dwellSeconds
                && !croppedTrackIDs.contains(track.id)
        }
        guard !ripe.isEmpty else { return [] }

        // Marked before the crop, not after: the crop is awaited, and a second frame
        // arriving in between would otherwise see the same track as uncropped and cut it
        // twice.
        for track in ripe {
            croppedTrackIDs.insert(track.id)
        }

        let requests = ripe.map { (id: $0.id, label: $0.label, box: $0.box) }
        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
                let context = CIContext(options: [.useSoftwareRenderer: false])
                let image = CIImage(cvPixelBuffer: wrapper.pixelBuffer)
                let cropped = requests.compactMap { request in
                    Self.crop(image, to: request.box, in: context).map { data in
                        ObjectDetectionClient.MaturedObject(
                            id: request.id,
                            label: request.label,
                            croppedData: data
                        )
                    }
                }
                continuation.resume(returning: cropped)
            }
        }
    }

    /// One object's crop as JPEG bytes, padded and capped for a thumbnail.
    ///
    /// The box is normalised with a top-left origin; Core Image measures y upward from the
    /// bottom, so the rect is flipped before it cuts.
    private static func crop(
        _ image: CIImage,
        to box: TrackBox,
        in context: CIContext
    ) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let width = CGFloat(box.width) * extent.width
        let height = CGFloat(box.height) * extent.height
        let padding = max(width, height) * Self.cropPaddingRatio
        let originX = max(0, CGFloat(box.x) * extent.width - padding)
        let topOriginY = max(0, CGFloat(box.y) * extent.height - padding)
        let paddedWidth = min(extent.width - originX, width + padding * 2)
        let paddedHeight = min(extent.height - topOriginY, height + padding * 2)
        guard paddedWidth > 0, paddedHeight > 0 else { return nil }

        let rect = CGRect(
            x: extent.minX + originX,
            y: extent.minY + extent.height - topOriginY - paddedHeight,
            width: paddedWidth,
            height: paddedHeight
        )

        var cut = image.cropped(to: rect)
        let longestEdge = max(cut.extent.width, cut.extent.height)
        if longestEdge > Self.cropMaxDimension {
            let scale = Self.cropMaxDimension / longestEdge
            cut = cut.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.jpegRepresentation(
            of: cut,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
    }

    /// Context kept around the detector's box, as a fraction of its longer side. The model
    /// brackets an object tightly and a crop with no margin reads as a mistake.
    private static let cropPaddingRatio: CGFloat = 0.1
    /// Longest edge of a crop. These are thumbnails held in memory by the consumer, not
    /// the full-resolution image a scan would want.
    private static let cropMaxDimension: CGFloat = 360

    /// Starts a background monocular-depth refresh when the device delivers no hardware depth and the
    /// cadence is due. Non-blocking: the current frame samples whatever estimate is already cached
    /// (centre-proximity until the first lands), and the result updates `monocularDepth` for later
    /// frames. On a device with hardware depth this returns at once and never loads the depth model.
    private func refreshMonocularDepthIfNeeded(for wrapper: PhotoCaptureClient.PixelBufferWrapper) {
        guard wrapper.depthBuffer == nil else { return }
        monocularDepthFrameCounter += 1
        let due = monocularDepth == nil || monocularDepthFrameCounter % Self.monocularDepthInterval == 0
        guard due else { return }
        Task {
            let estimate = await depthEstimator.estimate(wrapper)
            monocularDepth = estimate?.buffer ?? monocularDepth
        }
    }

    /// Run YOLO inference for one frame off the actor (on `inferenceQueue`), sampling per-box depth and
    /// estimating camera motion versus the previous frame. Returns `nil` on non-iOS or a Vision failure.
    private func runInference(
        wrapper: PhotoCaptureClient.PixelBufferWrapper,
        previousWrapper: PhotoCaptureClient.PixelBufferWrapper?,
        vnModel: VNCoreMLModel,
        configuration: ObjectDetectionClient.Configuration,
        motionEstimator: CameraMotionEstimator,
        depthBuffer: DepthMap?
    ) async -> (detections: [Detection], inferenceMs: Double, cameraMotion: CameraMotion)? {
        await withCheckedContinuation { continuation in
            inferenceQueue.async {
                let start = CFAbsoluteTimeGetCurrent()

                #if canImport(UIKit)
                    let request = VNCoreMLRequest(model: vnModel)
                    request.imageCropAndScaleOption = .scaleFill

                    // Use CVPixelBuffer directly — avoids CIImage allocation per frame.
                    let handler = VNImageRequestHandler(cvPixelBuffer: wrapper.pixelBuffer, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }

                    let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    var detections: [Detection] = []

                    if let results = request.results as? [VNRecognizedObjectObservation] {
                        for prediction in results.prefix(configuration.maxDetections) {
                            let conf = prediction.labels[0].confidence
                            guard conf >= configuration.confidenceThreshold else { continue }

                            let visionBox = prediction.boundingBox
                            // Vision uses bottom-left origin → convert to top-left.
                            let box = TrackBox(
                                x: Float(visionBox.minX),
                                y: Float(1 - visionBox.maxY),
                                width: Float(visionBox.width),
                                height: Float(visionBox.height)
                            )

                            // Sample Z depth at the box centre from hardware depth, or the monocular
                            // fallback on devices without a depth sensor (nil until the first estimate).
                            let depth = DepthSampler.sample(
                                in: depthBuffer?.buffer,
                                centerX: box.x + box.width * 0.5,
                                centerY: box.y + box.height * 0.5,
                                boxWidth: box.width,
                                boxHeight: box.height
                            )

                            detections.append(
                                Detection(
                                    box: box,
                                    confidence: conf,
                                    label: prediction.labels[0].identifier,
                                    depth: depth
                                )
                            )
                        }
                    }

                    // Estimate global camera motion (previous → current) for CMC — identity on the
                    // first frame or when registration fails.
                    let cameraMotion =
                        previousWrapper.map {
                            motionEstimator.estimate(
                                previous: $0.pixelBuffer,
                                current: wrapper.pixelBuffer
                            )
                        } ?? .identity

                    continuation.resume(returning: (detections, inferenceTime, cameraMotion))
                #else
                    continuation.resume(returning: nil)
                #endif
            }
        }
    }
}
