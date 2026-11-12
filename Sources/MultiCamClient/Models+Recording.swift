import CasePaths
import CoreGraphics
import CoreVideo
import Foundation
import PhotoCaptureClient

#if os(iOS)
    import UIKit
#endif

// MARK: - Video Stabilization

extension MultiCamClient {
    public enum StabilizationMode: String, Sendable, Equatable, CaseIterable, Codable {
        case off
        case standard
        case cinematic
        case cinematicExtended
        case auto

        public var label: String {
            switch self {
                case .off: "Off"
                case .standard: "Standard"
                case .cinematic: "Cinematic"
                case .cinematicExtended: "Cinematic Ext"
                case .auto: "Auto"
            }
        }
    }
}

// MARK: - Recording Configuration

extension MultiCamClient {
    public struct RecordingConfiguration: Sendable, Equatable {
        public var outputMode: OutputMode
        public var includeAudio: Bool
        public var videoCodec: VideoCodec
        public var audioBitRate: Int
        public var videoBitRate: Int
        /// Output width in pixels for the composited recording.
        /// Height is derived from screen aspect ratio.
        public var outputWidth: Int

        public init(
            outputMode: OutputMode = .combined,
            includeAudio: Bool = true,
            videoCodec: VideoCodec = .h264,
            audioBitRate: Int = 128_000,
            videoBitRate: Int = 10_000_000,
            outputWidth: Int = 1080
        ) {
            self.outputMode = outputMode
            self.includeAudio = includeAudio
            self.videoCodec = videoCodec
            self.audioBitRate = audioBitRate
            self.videoBitRate = videoBitRate
            self.outputWidth = max(2, outputWidth)
        }
    }

    public enum OutputMode: String, Sendable, Equatable, CaseIterable {
        /// Single video with all cameras composited per layout.
        case combined
        /// One file per camera.
        case individual
        /// Both combined + individual files.
        case both
    }

    public enum VideoCodec: String, Sendable, Equatable, CaseIterable {
        case h264
        case hevc
    }
}

// MARK: - Recording Result

extension MultiCamClient {
    public struct RecordingResult: Sendable, Equatable {
        public let combinedURL: URL?
        public let individualURLs: [CameraID: URL]
        public let duration: TimeInterval
        public let timestamp: Date

        public init(
            combinedURL: URL? = nil,
            individualURLs: [CameraID: URL] = [:],
            duration: TimeInterval = 0,
            timestamp: Date = .now
        ) {
            self.combinedURL = combinedURL
            self.individualURLs = individualURLs
            self.duration = duration
            self.timestamp = timestamp
        }
    }
}

// MARK: - Composite Photo Capture Result

extension MultiCamClient {
    public struct CompositePhotoCaptureResult: Sendable, Equatable {
        public let combinedPhoto: PhotoCaptureClient.Photo?
        public let individualPhotos: [CameraID: PhotoCaptureClient.Photo]
        public let timestamp: Date

        public init(
            combinedPhoto: PhotoCaptureClient.Photo? = nil,
            individualPhotos: [CameraID: PhotoCaptureClient.Photo] = [:],
            timestamp: Date = .now
        ) {
            self.combinedPhoto = combinedPhoto
            self.individualPhotos = individualPhotos
            self.timestamp = timestamp
        }
    }
}
