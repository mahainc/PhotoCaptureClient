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
        // MARK: - Capability

        nonisolated func queryCapability() -> MultiCamClient.DeviceCapability {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                return MultiCamClient.DeviceCapability(
                    isMultiCamSupported: false,
                    availableCameraSets: [],
                    maxSimultaneousCameras: 0
                )
            }

            // Use Apple's discovery API to get real valid multi-cam combinations
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera,
                    .builtInUltraWideCamera,
                    .builtInTelephotoCamera,
                ],
                mediaType: .video,
                position: .unspecified
            )

            let cameraSets = sortedByPreference(
                collectCameraSets(from: discovery.supportedMultiCamDeviceSets)
            )

            return MultiCamClient.DeviceCapability(
                isMultiCamSupported: true,
                availableCameraSets: cameraSets,
                maxSimultaneousCameras: cameraSets.map(\.count).max() ?? 2
            )
        }

        /// Every unique camera set the device supports: each discovered full set plus every
        /// 2-camera subset of it, de-duplicated by their sorted-id key.
        private nonisolated func collectCameraSets(
            from deviceSets: [Set<AVCaptureDevice>]
        ) -> [[MultiCamClient.CameraID]] {
            var seen = Set<String>()
            return
                deviceSets
                .compactMap { deviceSet -> [MultiCamClient.CameraID]? in
                    let ids = deviceSet.compactMap { mapDeviceToCameraID($0) }
                    guard !ids.isEmpty else { return nil }
                    return ids.sorted { $0.rawValue < $1.rawValue }
                }
                .flatMap { sorted in [sorted] + cameraPairs(from: sorted) }
                .filter { seen.insert($0.map(\.rawValue).joined(separator: ",")).inserted }
        }

        /// Orders camera sets with the larger sets first, then alphabetically by id.
        private nonisolated func sortedByPreference(
            _ cameraSets: [[MultiCamClient.CameraID]]
        ) -> [[MultiCamClient.CameraID]] {
            cameraSets.sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.map(\.rawValue).joined() < b.map(\.rawValue).joined()
            }
        }

        /// All unique 2-camera pairs within a 3+ camera set, for `queryCapability`'s subset expansion.
        private nonisolated func cameraPairs(
            from sorted: [MultiCamClient.CameraID]
        ) -> [[MultiCamClient.CameraID]] {
            guard sorted.count > 2 else { return [] }
            var pairs: [[MultiCamClient.CameraID]] = []
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    pairs.append([sorted[i], sorted[j]])
                }
            }
            return pairs
        }

        private nonisolated func mapDeviceToCameraID(_ device: AVCaptureDevice) -> MultiCamClient.CameraID? {
            switch (device.deviceType, device.position) {
                case (.builtInWideAngleCamera, .front): return .frontWide
                case (.builtInWideAngleCamera, .back): return .backWide
                case (.builtInUltraWideCamera, .back): return .backUltraWide
                case (.builtInTelephotoCamera, .back): return .backTelephoto
                default: return nil
            }
        }
    }
#endif
