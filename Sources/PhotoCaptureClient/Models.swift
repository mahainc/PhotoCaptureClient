import Foundation
import CoreGraphics
import CoreVideo
import CasePaths
import QuartzCore

// MARK: - Photo

extension PhotoCaptureClient {
	/// Captured photo data extracted from AVCapturePhoto at the delegate boundary.
	/// AVCapturePhoto has no public initializer, so this wrapper enables mock construction.
	public struct Photo: Sendable, Equatable {
		public let fileDataRepresentation: Data?
		public let photoDimensions: CGSize
		public let timestamp: Date
		public let isRawPhoto: Bool

		public init(
			fileDataRepresentation: Data? = nil,
			photoDimensions: CGSize = .zero,
			timestamp: Date = .now,
			isRawPhoto: Bool = false
		) {
			self.fileDataRepresentation = fileDataRepresentation
			self.photoDimensions = photoDimensions
			self.timestamp = timestamp
			self.isRawPhoto = isRawPhoto
		}
	}
}

// MARK: - PhotoSettings

extension PhotoCaptureClient {
	/// Configuration for a photo capture request.
	/// Wraps AVCapturePhotoSettings properties across the concurrency boundary.
	public struct PhotoSettings: Sendable, Equatable {
		public var flashMode: FlashMode
		public var qualityPrioritization: QualityPrioritization

		public init(
			flashMode: FlashMode = .auto,
			qualityPrioritization: QualityPrioritization = .balanced
		) {
			self.flashMode = flashMode
			self.qualityPrioritization = qualityPrioritization
		}
	}
}

// MARK: - FlashMode

extension PhotoCaptureClient {
	public enum FlashMode: Sendable, Equatable {
		case off
		case on
		case auto
	}
}

// MARK: - CameraPosition

extension PhotoCaptureClient {
	public enum CameraPosition: Sendable, Equatable {
		case front
		case back
	}
}

// MARK: - QualityPrioritization

extension PhotoCaptureClient {
	public enum QualityPrioritization: Sendable, Equatable {
		case speed
		case balanced
		case quality
	}
}

// MARK: - AuthorizationStatus

extension PhotoCaptureClient {
	public enum AuthorizationStatus: Sendable, Equatable {
		case notDetermined
		case restricted
		case denied
		case authorized
	}
}

// MARK: - Event

extension PhotoCaptureClient {
	/// Events emitted by the photo capture session.
	@CasePathable
	public enum Event: Sendable, Equatable {
		// Session lifecycle
		case sessionStarted
		case sessionStopped
		case sessionInterrupted(InterruptionReason)
		case sessionInterruptionEnded
		case sessionRuntimeError(String)

		// Capture progress
		case willBeginCapture
		case willCapturePhoto
		case didCapturePhoto
		case captureCompleted
	}
}

// MARK: - InterruptionReason

extension PhotoCaptureClient {
	public enum InterruptionReason: Sendable, Equatable {
		case videoDeviceNotAvailableInBackground
		case audioDeviceInUseByAnotherClient
		case videoDeviceInUseByAnotherClient
		case videoDeviceNotAvailableWithMultipleForegroundApps
		case videoDeviceNotAvailableDueToSystemPressure
		case unknown
	}
}

// MARK: - PreviewLayer

extension PhotoCaptureClient {
	/// A Sendable wrapper around AVCaptureVideoPreviewLayer (a CALayer subclass).
	/// CALayer is not Sendable, so this wrapper enables crossing isolation boundaries.
	public final class PreviewLayer: @unchecked Sendable, Equatable {
		public let layer: CALayer

		public init(layer: CALayer) {
			self.layer = layer
		}

		public static func == (lhs: PreviewLayer, rhs: PreviewLayer) -> Bool {
			lhs.layer === rhs.layer
		}
	}
}

// MARK: - PixelBufferWrapper

extension PhotoCaptureClient {
	/// A Sendable wrapper around CVPixelBuffer for crossing isolation boundaries.
	/// CVPixelBuffer is not Sendable, so this wrapper retains it and exposes metadata.
	/// Follows the same pattern as `PreviewLayer`.
	public final class PixelBufferWrapper: @unchecked Sendable {
		/// The underlying pixel buffer. Retained for the lifetime of this wrapper.
		public let pixelBuffer: CVPixelBuffer
		public let width: Int
		public let height: Int
		public let bytesPerRow: Int
		public let timestamp: Date

		public init(
			pixelBuffer: CVPixelBuffer,
			width: Int,
			height: Int,
			bytesPerRow: Int,
			timestamp: Date = .now
		) {
			self.pixelBuffer = pixelBuffer
			self.width = width
			self.height = height
			self.bytesPerRow = bytesPerRow
			self.timestamp = timestamp
		}
	}
}

// MARK: - Error

extension PhotoCaptureClient {
	public enum Error: Swift.Error, Sendable, LocalizedError {
		case cameraUnavailable
		case captureSessionAlreadyRunning
		case captureSessionNotRunning
		case captureDeviceNotFound(CameraPosition)
		case cannotAddInput
		case cannotAddOutput
		case captureFailed(String)
		case notAuthorized
		case focusModeNotSupported
		case zoomFactorOutOfRange(min: CGFloat, max: CGFloat)

		public var errorDescription: String? {
			switch self {
			case .cameraUnavailable:
				return "Camera is unavailable on this device"
			case .captureSessionAlreadyRunning:
				return "Capture session is already running"
			case .captureSessionNotRunning:
				return "Capture session is not running"
			case .captureDeviceNotFound(let position):
				return "No \(position) camera found"
			case .cannotAddInput:
				return "Cannot add camera input to capture session"
			case .cannotAddOutput:
				return "Cannot add photo output to capture session"
			case .captureFailed(let reason):
				return "Photo capture failed: \(reason)"
			case .notAuthorized:
				return "Camera access is not authorized"
			case .focusModeNotSupported:
				return "Auto focus is not supported on this device"
			case .zoomFactorOutOfRange(let min, let max):
				return "Zoom factor must be between \(min) and \(max)"
			}
		}

		public var recoverySuggestion: String? {
			switch self {
			case .cameraUnavailable:
				return "This device does not have a camera."
			case .notAuthorized:
				return "Go to Settings > Privacy > Camera to grant access."
			case .captureDeviceNotFound:
				return "Try using a different camera position."
			default:
				return nil
			}
		}
	}
}
