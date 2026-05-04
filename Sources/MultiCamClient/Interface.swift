import DependenciesMacros
import Foundation
import PhotoCaptureClient
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A dependency client for simultaneous multi-camera capture and video recording.
///
/// `MultiCamClient` provides a testable, injectable interface for multi-camera session
/// management, layout configuration, video recording, and export.
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.multiCam) var multiCam
///
/// // Start dual-camera session
/// try await multiCam.startSession(.init(cameras: [.frontWide, .backWide]))
///
/// // Switch to PiP layout
/// await multiCam.setLayout(.pip(.init(primary: .backWide, overlay: .frontWide)))
///
/// // Record video
/// try await multiCam.startRecording(.init(outputMode: .combined, includeAudio: true))
/// let result = try await multiCam.stopRecording()
/// ```
@DependencyClient
public struct MultiCamClient: Sendable {

	// MARK: - Capability Check

	/// Query device capabilities for multi-camera support.
	public var deviceCapability: @Sendable () -> DeviceCapability = {
		DeviceCapability()
	}

	// MARK: - Session Lifecycle

	/// Start a multi-camera capture session with the specified configuration.
	public var startSession: @Sendable (_ configuration: SessionConfiguration) async throws -> Void

	/// Stop the current multi-camera session and release all resources.
	public var stopSession: @Sendable () async -> Void = {}

	// MARK: - Layout

	/// Set the display layout for the multi-camera preview and recording.
	public var setLayout: @Sendable (_ layout: Layout) async -> Void = { _ in }

	/// Get the current display layout.
	public var currentLayout: @Sendable () async -> Layout = { .grid(.init()) }

	// MARK: - Per-Camera Zoom

	/// Set the optical zoom factor for a specific camera.
	public var setZoom: @Sendable (_ camera: CameraID, _ factor: CGFloat) async throws -> Void

	/// Get the supported zoom range (min, max) for a specific camera.
	public var zoomRange: @Sendable (_ camera: CameraID) async -> (min: CGFloat, max: CGFloat) = { _ in (1.0, 1.0) }

	// MARK: - Video Stabilization

	/// Set stabilization mode for a specific camera.
	public var setStabilization: @Sendable (_ camera: CameraID, _ mode: StabilizationMode) async -> Void = { _, _ in }

	/// Set the camera draw order (first = background, rest = overlays).
	public var setCameraOrder: @Sendable (_ cameras: [CameraID]) async -> Void = { _ in }

	/// Set the torch (flashlight) mode for the back camera.
	public var setTorch: @Sendable (_ mode: TorchMode) async -> Void = { _ in }

	/// Set border style for PiP overlay cameras.
	/// - Parameters:
	///   - width: Border width in normalized viewport space (0 = no border, 0.02 = thin, 0.05 = thick)
	///   - colorRGBA: Border color as (r, g, b, a) with values 0-1
	public var setPiPBorder: @Sendable (_ width: Float, _ r: Float, _ g: Float, _ b: Float) async -> Void = { _, _, _, _ in }

	/// Fast-path live update of a PiP overlay's origin during drag.
	/// Bypasses the full layout pipeline (no event broadcast, no full viewport recompute).
	/// The canonical layout should still be committed via `setLayout` on drag end.
	/// - Parameters:
	///   - camera: The PiP overlay camera to move.
	///   - position: Normalized top-left origin in 0...1 viewport space.
	public var setPiPOverlayPosition: @Sendable (_ camera: CameraID, _ position: CGPoint) async -> Void = { _, _ in }

	// MARK: - Recording

	/// Start recording video from all active cameras.
	public var startRecording: @Sendable (_ configuration: RecordingConfiguration) async throws -> Void

	/// Pause the current recording. Frames are not written while paused.
	public var pauseRecording: @Sendable () async -> Void = {}

	/// Resume a paused recording.
	public var resumeRecording: @Sendable () async -> Void = {}

	/// Stop recording and return the result with file URLs.
	public var stopRecording: @Sendable () async throws -> RecordingResult

	// MARK: - Photo Capture

	/// Capture a photo from a specific camera while the session is running.
	/// Works during recording as well.
	public var capturePhoto: @Sendable (_ camera: CameraID) async throws -> PhotoCaptureClient.Photo

	/// Capture a composite photo (all cameras rendered with current layout) plus individual per-camera photos.
	public var captureCompositePhoto: @Sendable (_ outputSize: CGSize) async throws -> CompositePhotoCaptureResult

	// MARK: - Authorization

	/// Request camera and microphone authorization.
	public var requestAuthorization: @Sendable () async -> PhotoCaptureClient.AuthorizationStatus = { .notDetermined }

	/// Check current authorization status.
	public var authorizationStatus: @Sendable () -> PhotoCaptureClient.AuthorizationStatus = { .notDetermined }

	// MARK: - Observation

	/// Stream of events from the multi-camera session.
	public var events: @Sendable () async -> AsyncStream<Event> = { AsyncStream { _ in } }

	// MARK: - Preview

	/// Get the composited multi-camera preview view.
	public var previewView: @Sendable () async -> PreviewView = {
		await MainActor.run {
			#if os(iOS)
			PreviewView(view: UIView())
			#else
			PreviewView(view: NSView())
			#endif
		}
	}

	// MARK: - Per-Camera Frame Access

	/// Stream of pixel buffers from a specific camera. Useful for per-camera processing
	/// (e.g., object detection on one camera feed).
	public var pixelBufferStream: @Sendable (_ camera: CameraID) async -> AsyncStream<PhotoCaptureClient.PixelBufferWrapper> = { _ in
		AsyncStream { _ in }
	}
}
