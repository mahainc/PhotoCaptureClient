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

// MARK: - Streams

extension ObjectDetectionClientActor {
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

    func yieldResult(_ result: ObjectDetectionClient.DetectionResult) {
        for continuation in resultContinuations.values {
            continuation.yield(result)
        }
    }
}
