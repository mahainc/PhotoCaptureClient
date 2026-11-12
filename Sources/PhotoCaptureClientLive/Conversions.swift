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

// MARK: - AVFoundation → Domain Conversions

extension PhotoCaptureClient.FlashMode {
    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
            case .off: .off
            case .on: .on
            case .auto: .auto
        }
    }
}

extension PhotoCaptureClient.QualityPrioritization {
    var avQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization {
        switch self {
            case .speed: .speed
            case .balanced: .balanced
            case .quality: .quality
        }
    }
}

extension AVAuthorizationStatus {
    static func from(_ status: AVAuthorizationStatus) -> PhotoCaptureClient.AuthorizationStatus {
        switch status {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .authorized
            @unknown default: .notDetermined
        }
    }
}

#if os(iOS)
    extension AVCaptureSession.InterruptionReason {
        var domainReason: PhotoCaptureClient.InterruptionReason {
            switch self {
                case .videoDeviceNotAvailableInBackground:
                    .videoDeviceNotAvailableInBackground
                case .audioDeviceInUseByAnotherClient:
                    .audioDeviceInUseByAnotherClient
                case .videoDeviceInUseByAnotherClient:
                    .videoDeviceInUseByAnotherClient
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    .videoDeviceNotAvailableWithMultipleForegroundApps
                case .videoDeviceNotAvailableDueToSystemPressure:
                    .videoDeviceNotAvailableDueToSystemPressure
                case .sensitiveContentMitigationActivated:
                    .unknown
                @unknown default:
                    .unknown
            }
        }
    }
#endif
