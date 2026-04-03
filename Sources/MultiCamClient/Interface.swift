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

	// MARK: - Recording

	/// Start recording video from all active cameras.
	public var startRecording: @Sendable (_ configuration: RecordingConfiguration) async throws -> Void

	/// Stop recording and return the result with file URLs.
	public var stopRecording: @Sendable () async throws -> RecordingResult

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
