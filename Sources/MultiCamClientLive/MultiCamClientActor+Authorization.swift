#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreMedia
    import Foundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    extension MultiCamClientActor {
        // MARK: - Authorization

        func requestAuthorization() async -> PhotoCaptureClient.AuthorizationStatus {
            let videoGranted = await AVCaptureDevice.requestAccess(for: .video)
            let audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
            return (videoGranted && audioGranted) ? .authorized : .denied
        }

        nonisolated func authorizationStatus() -> PhotoCaptureClient.AuthorizationStatus {
            let video = AVCaptureDevice.authorizationStatus(for: .video)
            let audio = AVCaptureDevice.authorizationStatus(for: .audio)
            guard bothAuthorized(video: video, audio: audio) else {
                if eitherNotDetermined(video: video, audio: audio) { return .notDetermined }
                if eitherRestricted(video: video, audio: audio) { return .restricted }
                return .denied
            }
            return .authorized
        }

        private nonisolated func bothAuthorized(
            video: AVAuthorizationStatus,
            audio: AVAuthorizationStatus
        ) -> Bool {
            video == .authorized && audio == .authorized
        }

        private nonisolated func eitherNotDetermined(
            video: AVAuthorizationStatus,
            audio: AVAuthorizationStatus
        ) -> Bool {
            video == .notDetermined || audio == .notDetermined
        }

        private nonisolated func eitherRestricted(
            video: AVAuthorizationStatus,
            audio: AVAuthorizationStatus
        ) -> Bool {
            video == .restricted || audio == .restricted
        }
    }
#endif
