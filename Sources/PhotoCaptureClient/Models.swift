import Foundation
import CoreGraphics
import CoreVideo
import CasePaths
import QuartzCore
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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

		// Zoom
		case zoomChanged(CGFloat)
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

// MARK: - PreviewView

extension PhotoCaptureClient {
	/// A Sendable wrapper around a UIView (Metal-backed camera preview).
	/// UIView is not Sendable, so this wrapper enables crossing isolation boundaries.
	public final class PreviewView: @unchecked Sendable, Equatable {
		#if os(iOS)
		public let view: UIView
		#else
		public let view: NSView
		#endif

		/// Aspect-fill UV scale — how much of the texture is visible (1.0 = full, <1.0 = cropped).
		/// Updated by the renderer whenever drawable or texture size changes. Read on main thread.
		public var uvScale: SIMD2<Float> = SIMD2<Float>(1, 1)

		/// Aspect-fill UV offset — the origin offset of the visible texture region.
		/// Updated by the renderer whenever drawable or texture size changes. Read on main thread.
		public var uvOffset: SIMD2<Float> = SIMD2<Float>(0, 0)

		/// Visual zoom factor — updated by the renderer. 1.0 = no zoom.
		public var visualZoomFactor: Float = 1.0
		/// Visual zoom anchor X in screen UV space (0-1).
		public var visualZoomAnchorX: Float = 0.5
		/// Visual zoom anchor Y in screen UV space (0-1).
		public var visualZoomAnchorY: Float = 0.5

		#if os(iOS)
		public init(view: UIView) {
			self.view = view
		}
		#else
		public init(view: NSView) {
			self.view = view
		}
		#endif

		/// Convert a normalized texture coordinate (0-1) to a view-relative coordinate (0-1),
		/// accounting for aspect-fill cropping and visual zoom.
		public func textureToView(x: Float, y: Float) -> (x: Float, y: Float) {
			// First: aspect-fill mapping (texture UV → screen UV without zoom)
			let screenX = (x - uvOffset.x) / uvScale.x
			let screenY = (y - uvOffset.y) / uvScale.y
			// Then: apply zoom transform (inverse of shader division → multiply)
			let zoomedX = (screenX - visualZoomAnchorX) * visualZoomFactor + visualZoomAnchorX
			let zoomedY = (screenY - visualZoomAnchorY) * visualZoomFactor + visualZoomAnchorY
			return (x: zoomedX, y: zoomedY)
		}

		/// Convert a normalized texture size to a view-relative size, accounting for aspect-fill and zoom.
		public func textureToViewSize(w: Float, h: Float) -> (w: Float, h: Float) {
			return (w / uvScale.x * visualZoomFactor, h / uvScale.y * visualZoomFactor)
		}

		public static func == (lhs: PreviewView, rhs: PreviewView) -> Bool {
			lhs.view === rhs.view
		}
	}
}

// MARK: - PixelBufferWrapper

extension PhotoCaptureClient {
	/// A Sendable wrapper around CVPixelBuffer for crossing isolation boundaries.
	/// CVPixelBuffer is not Sendable, so this wrapper retains it and exposes metadata.
	/// Follows the same pattern as `PreviewView`.
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

// MARK: - OverlayRect

extension PhotoCaptureClient {
	/// A normalized overlay rectangle for drawing on the Metal preview.
	/// Coordinates are in 0.0-1.0 space (top-left origin).
	/// Color is RGBA with values in range [0.0, 1.0].
	public struct OverlayRect: Sendable, Equatable {
		public let x: Float
		public let y: Float
		public let width: Float
		public let height: Float
		public let label: String?
		public let confidence: Float?
		public let color: SIMD4<Float>

		public init(
			x: Float,
			y: Float,
			width: Float,
			height: Float,
			label: String? = nil,
			confidence: Float? = nil,
			color: SIMD4<Float> = SIMD4<Float>(0, 1, 0, 1)
		) {
			self.x = x
			self.y = y
			self.width = width
			self.height = height
			self.label = label
			self.confidence = confidence
			self.color = color
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
