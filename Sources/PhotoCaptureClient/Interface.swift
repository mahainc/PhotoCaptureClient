import DependenciesMacros
import Foundation
import QuartzCore

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

	// MARK: - Authorization

	public var requestAuthorization: @Sendable () async -> AuthorizationStatus = { .notDetermined }

	public var authorizationStatus: @Sendable () -> AuthorizationStatus = { .notDetermined }

	// MARK: - Observation

	public var events: @Sendable () async -> AsyncStream<Event> = { AsyncStream { _ in } }

	// MARK: - Preview

	public var previewLayer: @Sendable () async -> PreviewLayer = { PreviewLayer(layer: CALayer()) }
}
