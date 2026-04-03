import CasePaths
import CoreGraphics
import CoreVideo
import Foundation
import PhotoCaptureClient
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Aspect Ratio

extension MultiCamClient {
	public enum AspectRatio: String, Sendable, Equatable, Codable, CaseIterable {
		case ratio9x16 = "9:16"
		case ratio16x9 = "16:9"
		case ratio1x1 = "1:1"
		case ratio4x3 = "4:3"

		public var label: String { rawValue }

		/// Output size for a given base resolution (short edge).
		public func outputSize(baseWidth: Int) -> (width: Int, height: Int) {
			switch self {
			case .ratio9x16: return (baseWidth, baseWidth * 16 / 9)
			case .ratio16x9: return (baseWidth * 16 / 9, baseWidth)
			case .ratio1x1:  return (baseWidth, baseWidth)
			case .ratio4x3:  return (baseWidth, baseWidth * 4 / 3)
			}
		}
	}
}

// MARK: - Layout Preset

extension MultiCamClient {
	public enum LayoutPreset: String, Sendable, Equatable, CaseIterable, Codable {
		case equal
		case stacked
		case focusFirst
		case focusLast
		case pip

		public var icon: String {
			switch self {
			case .equal: "rectangle.3.group"
			case .stacked: "rectangle.grid.1x3"
			case .focusFirst: "rectangle.leadinghalf.inset.filled"
			case .focusLast: "rectangle.trailinghalf.inset.filled"
			case .pip: "pip"
			}
		}

		public var label: String {
			switch self {
			case .equal: "Equal"
			case .stacked: "Stacked"
			case .focusFirst: "Focus Left"
			case .focusLast: "Focus Right"
			case .pip: "PiP"
			}
		}
	}
}

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

// MARK: - Layout

extension MultiCamClient {
	/// How cameras are composited for preview and recording.
	public enum Layout: Sendable, Equatable {
		case grid(GridLayout)
		case pip(PiPLayout)
		case custom(CustomLayout)
	}

	public struct GridLayout: Sendable, Equatable {
		/// Number of columns. 1 = vertical stack, 2 = side-by-side or 2x2.
		public var columns: Int

		public init(columns: Int = 2) {
			self.columns = max(1, columns)
		}
	}

	public struct PiPLayout: Sendable, Equatable {
		public var primary: CameraID
		public var overlay: CameraID
		public var overlayPosition: PiPPosition
		/// Fraction of primary view size (0.0-1.0).
		public var overlayScale: CGFloat

		public init(
			primary: CameraID = .backWide,
			overlay: CameraID = .frontWide,
			overlayPosition: PiPPosition = .bottomTrailing,
			overlayScale: CGFloat = 0.25
		) {
			self.primary = primary
			self.overlay = overlay
			self.overlayPosition = overlayPosition
			self.overlayScale = min(max(overlayScale, 0.1), 0.5)
		}
	}

	public enum PiPPosition: Sendable, Equatable {
		case topLeading
		case topTrailing
		case bottomLeading
		case bottomTrailing
		/// Custom normalized position (0-1 space, origin = top-left).
		case custom(x: CGFloat, y: CGFloat)
	}

	public struct CustomLayout: Sendable, Equatable {
		/// Per-camera normalized frame (origin + size in 0-1 space).
		public var frames: [CameraID: CGRect]
		/// Per-camera corner radius (0 = sharp, 0.5 = circular).
		public var cornerRadii: [CameraID: CGFloat]

		public init(frames: [CameraID: CGRect], cornerRadii: [CameraID: CGFloat] = [:]) {
			self.frames = frames
			self.cornerRadii = cornerRadii
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

		public init(
			outputMode: OutputMode = .combined,
			includeAudio: Bool = true,
			videoCodec: VideoCodec = .h264,
			audioBitRate: Int = 128_000,
			videoBitRate: Int = 10_000_000
		) {
			self.outputMode = outputMode
			self.includeAudio = includeAudio
			self.videoCodec = videoCodec
			self.audioBitRate = audioBitRate
			self.videoBitRate = videoBitRate
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

// MARK: - Event

extension MultiCamClient {
	@CasePathable
	public enum Event: Sendable, Equatable {
		// Session lifecycle
		case sessionStarted
		case sessionStopped
		case sessionError(String)
		case sessionInterrupted(String)
		case sessionInterruptionEnded

		// Camera lifecycle
		case cameraConnected(CameraID)
		case cameraDisconnected(CameraID)

		// Recording lifecycle
		case recordingStarted
		case recordingPaused
		case recordingResumed
		case recordingStopped(RecordingResult)
		case recordingError(String)

		// Photo capture
		case photoCaptured(CameraID)

		// Layout
		case layoutChanged(Layout)

		// Zoom
		case zoomChanged(CameraID, CGFloat)

		// System pressure
		case systemPressureChanged(SystemPressureLevel)
		case hardwareCostUpdated(Float)
	}

	/// Maps to AVCaptureDevice.SystemPressureState.Level
	public enum SystemPressureLevel: String, Sendable, Equatable {
		case nominal
		case fair
		case serious
		case critical
		case shutdown
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

// MARK: - PreviewView

extension MultiCamClient {
	/// A Sendable wrapper around a UIView (Metal-backed multi-camera preview).
	public final class PreviewView: @unchecked Sendable, Equatable {
		#if os(iOS)
		public let view: UIView
		#else
		public let view: NSView
		#endif

		/// Current layout applied to the preview.
		public var layout: Layout

		#if os(iOS)
		public init(view: UIView, layout: Layout = .grid(.init())) {
			self.view = view
			self.layout = layout
		}
		#else
		public init(view: NSView, layout: Layout = .grid(.init())) {
			self.view = view
			self.layout = layout
		}
		#endif

		public static func == (lhs: PreviewView, rhs: PreviewView) -> Bool {
			lhs.view === rhs.view
		}
	}
}

// MARK: - Error

extension MultiCamClient {
	public enum Error: Swift.Error, Sendable, LocalizedError {
		case multiCamNotSupported
		case cameraSetNotSupported([CameraID])
		case sessionAlreadyRunning
		case sessionNotRunning
		case recordingAlreadyInProgress
		case recordingNotInProgress
		case recordingFailed(String)
		case exportFailed(String)
		case notAuthorized
		case audioDeviceUnavailable

		public var errorDescription: String? {
			switch self {
			case .multiCamNotSupported:
				return "Multi-camera capture is not supported on this device"
			case .cameraSetNotSupported(let cameras):
				return "Camera combination not supported: \(cameras.map(\.rawValue).joined(separator: ", "))"
			case .sessionAlreadyRunning:
				return "Multi-cam session is already running"
			case .sessionNotRunning:
				return "Multi-cam session is not running"
			case .recordingAlreadyInProgress:
				return "Recording is already in progress"
			case .recordingNotInProgress:
				return "No recording in progress"
			case .recordingFailed(let reason):
				return "Recording failed: \(reason)"
			case .exportFailed(let reason):
				return "Export failed: \(reason)"
			case .notAuthorized:
				return "Camera or microphone access is not authorized"
			case .audioDeviceUnavailable:
				return "Audio capture device is unavailable"
			}
		}

		public var recoverySuggestion: String? {
			switch self {
			case .multiCamNotSupported:
				return "This device does not support simultaneous multi-camera capture. Use single-camera mode instead."
			case .notAuthorized:
				return "Go to Settings > Privacy to grant camera and microphone access."
			default:
				return nil
			}
		}
	}
}
