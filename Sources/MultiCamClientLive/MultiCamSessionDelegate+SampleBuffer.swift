#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreImage
    import CoreMedia
    import Foundation
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    extension MultiCamSessionDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            let key = ObjectIdentifier(output)

            // Route video frames by camera ID
            if let cameraID = outputToCameraID[key] {
                onVideoFrame?(cameraID, sampleBuffer)
                return
            }

            // Route audio samples
            if output === audioOutput {
                onAudioSample?(sampleBuffer)
            }
        }
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    extension MultiCamSessionDelegate: AVCaptureAudioDataOutputSampleBufferDelegate {
        // Audio samples are routed through the same captureOutput method above
    }
#endif
