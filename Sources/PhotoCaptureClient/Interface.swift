import DependenciesMacros
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A dependency client wrapping AVFoundation's photo capture APIs for use with TCA.
///
/// `PhotoCaptureClient` provides a testable, injectable interface for camera session
/// management, photo capture, and device control.
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.photoCapture) var photoCapture
///
/// let photo = try await photoCapture.capturePhoto(.init(flashMode: .auto))
/// ```
@DependencyClient
public struct PhotoCaptureClient: Sendable {

	// MARK: - Session Lifecycle

	public var startSession: @Sendable () async throws -> Void

	public var stopSession: @Sendable () async -> Void = { }

	// MARK: - Photo Capture

	public var capturePhoto: @Sendable (_ settings: PhotoSettings) async throws -> Photo

	// MARK: - Camera Control

	public var switchCamera: @Sendable (_ position: CameraPosition) async throws -> Void

	public var setFlashMode: @Sendable (_ mode: FlashMode) async -> Void = { _ in }

	public var focus: @Sendable (_ point: CGPoint) async throws -> Void

	public var setZoomFactor: @Sendable (_ factor: CGFloat) async throws -> Void

	/// Set visual zoom in the Metal shader (not AVFoundation).
	/// - Parameters:
	///   - factor: Zoom level (1.0 = no zoom, max ~5.0)
	///   - anchorX: Normalized screen X coordinate of the zoom center (0-1)
	///   - anchorY: Normalized screen Y coordinate of the zoom center (0-1)
	public var setVisualZoom: @Sendable (_ factor: CGFloat, _ anchorX: CGFloat, _ anchorY: CGFloat) async -> Void = { _, _, _ in }

	// MARK: - Authorization

	public var requestAuthorization: @Sendable () async -> AuthorizationStatus = { .notDetermined }

	public var authorizationStatus: @Sendable () -> AuthorizationStatus = { .notDetermined }

	// MARK: - Observation

	public var events: @Sendable () async -> AsyncStream<Event> = { AsyncStream { _ in } }

	// MARK: - Frame Delivery

	/// Stream of pixel buffers from the camera. Used by ObjectDetectionClientLive for inference.
	public var pixelBufferStream: @Sendable () async -> AsyncStream<PixelBufferWrapper> = { AsyncStream { _ in } }

	// MARK: - Preview

	public var previewView: @Sendable () async -> PreviewView = {
		await MainActor.run {
			#if os(iOS)
			PreviewView(view: UIView())
			#else
			PreviewView(view: NSView())
			#endif
		}
	}

	// MARK: - Overlay

	/// Update bounding box overlays on the Metal preview. Pass empty array to clear.
	/// Note: Updates are best-effort ordered (acceptable since each call fully replaces all overlays).
	public var updateOverlays: @Sendable (_ overlays: [OverlayRect]) -> Void = { _ in }
}
