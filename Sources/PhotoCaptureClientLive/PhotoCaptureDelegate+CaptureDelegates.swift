@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HistogramKit
import ImageIO
import PhotoCaptureClient
import os

#if os(iOS)
    import UIKit
    import MetalKit
#endif

// MARK: - AVCapturePhotoCaptureDelegate

extension PhotoCaptureDelegate: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        onEvent?(.willBeginCapture)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        onEvent?(.willCapturePhoto)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        onEvent?(.didCapturePhoto)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Swift.Error)?
    ) {
        if let error {
            photoContinuation?.resume(throwing: PhotoCaptureClient.Error.captureFailed(error.localizedDescription))
            photoContinuation = nil
            return
        }

        let dimensions = photo.resolvedSettings.photoDimensions
        #if os(iOS)
            let isRaw = photo.isRawPhoto
        #endif
        let domainPhoto = PhotoCaptureClient.Photo(
            fileDataRepresentation: photo.fileDataRepresentation(),
            photoDimensions: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)),
            timestamp: .now,
            isRawPhoto: isRaw
        )
        photoContinuation?.resume(returning: domainPhoto)
        photoContinuation = nil
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: (any Swift.Error)?
    ) {
        onEvent?(.captureCompleted)

        // If didFinishProcessingPhoto was never called (e.g., error before processing)
        if let error, photoContinuation != nil {
            photoContinuation?.resume(throwing: PhotoCaptureClient.Error.captureFailed(error.localizedDescription))
            photoContinuation = nil
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PhotoCaptureDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Deliver every frame to Metal renderer at full camera rate
        onFrame?(pixelBuffer)

        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= frameIntervalSeconds else { return }
        lastFrameTime = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let wrapper = PhotoCaptureClient.PixelBufferWrapper(
            pixelBuffer: pixelBuffer,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            depthBuffer: latestDepthMap,
            timestamp: .now
        )

        pixelBufferContinuation?.yield(wrapper)
    }
}

// MARK: - AVCaptureDepthDataOutputDelegate

extension PhotoCaptureDelegate: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(
        _ output: AVCaptureDepthDataOutput,
        didOutput depthData: AVDepthData,
        timestamp: CMTime,
        connection: AVCaptureConnection
    ) {
        // Throttle to the detection cadence: the conversion + EXIF reorientation below are per-frame
        // CPU work, and nothing samples depth faster than video frames are throttled through.
        let now = CACurrentMediaTime()
        guard now - lastDepthTime >= depthIntervalSeconds else { return }
        lastDepthTime = now

        // Normalise to metric depth (metres, smaller = nearer). LiDAR/dual cameras may deliver
        // disparity or 16-bit depth; converting to DepthFloat32 guarantees comparable metres and a
        // fresh, non-pool backing buffer that is safe to retain past this callback (the wrapper's
        // strong CVPixelBuffer reference keeps it alive once attached).
        let metric =
            depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        // Orient the depth map to match the rotated/mirrored video buffer in software. Setting
        // videoRotationAngle on the depth connection does not reliably rotate depthDataMap, so the raw
        // map is sensor-native landscape; sampling a portrait box centre there reads a 90°-wrong (and,
        // front, mirrored) pixel. applyingExifOrientation rotates both the map and its calibration so
        // the existing top-left, portrait-normalised box centre samples the correct pixel.
        let oriented = metric.applyingExifOrientation(depthExifOrientation)
        let map = oriented.depthDataMap
        latestDepthMap = map
        #if DEBUG
            if !didLogDepth {
                didLogDepth = true
                onLog?(
                    "Depth map \(CVPixelBufferGetWidth(map))x\(CVPixelBufferGetHeight(map)) "
                        + "(portrait expects height > width), exif=\(depthExifOrientation.rawValue)"
                )
            }
        #endif
    }
}
