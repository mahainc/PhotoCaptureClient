import CasePaths
import CoreGraphics
import CoreVideo
import Foundation
import PhotoCaptureClient

#if os(iOS)
    import UIKit
#endif

// MARK: - Camera Identification

extension MultiCamClient {
    /// Identifies a specific camera in a multi-cam session.
    public struct CameraID: Sendable, Hashable, Codable, CustomStringConvertible {
        public let rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public static let frontWide = CameraID("front-wide")
        public static let backWide = CameraID("back-wide")
        public static let backUltraWide = CameraID("back-ultrawide")
        public static let backTelephoto = CameraID("back-telephoto")

        public var description: String { rawValue }
    }
}

// MARK: - Torch Mode

extension MultiCamClient {
    public enum TorchMode: String, Sendable, Equatable, CaseIterable {
        case off
        case on
        case auto
    }
}

// MARK: - Session Configuration

extension MultiCamClient {
    /// Describes which cameras to activate and at what resolution.
    public struct SessionConfiguration: Sendable, Equatable {
        public var cameras: [CameraID]
        public var preferredResolution: Resolution
        public var frameRate: Int
        public var includeAudio: Bool

        public init(
            cameras: [CameraID] = [.frontWide, .backWide],
            preferredResolution: Resolution = .hd1080p,
            frameRate: Int = 30,
            includeAudio: Bool = true
        ) {
            self.cameras = cameras
            self.preferredResolution = preferredResolution
            self.frameRate = max(1, min(frameRate, 240))
            self.includeAudio = includeAudio
        }
    }

    public enum Resolution: String, Sendable, Equatable, CaseIterable {
        case hd720p
        case hd1080p
        case uhd4K

        public var width: Int {
            switch self {
                case .hd720p: 1280
                case .hd1080p: 1920
                case .uhd4K: 3840
            }
        }

        public var height: Int {
            switch self {
                case .hd720p: 720
                case .hd1080p: 1080
                case .uhd4K: 2160
            }
        }
    }
}

// MARK: - Device Capability

extension MultiCamClient {
    public struct DeviceCapability: Sendable, Equatable {
        public let isMultiCamSupported: Bool
        public let availableCameraSets: [[CameraID]]
        public let maxSimultaneousCameras: Int

        public init(
            isMultiCamSupported: Bool = false,
            availableCameraSets: [[CameraID]] = [],
            maxSimultaneousCameras: Int = 0
        ) {
            self.isMultiCamSupported = isMultiCamSupported
            self.availableCameraSets = availableCameraSets
            self.maxSimultaneousCameras = maxSimultaneousCameras
        }
    }
}
