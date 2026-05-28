import Dependencies
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Dependency Registration

extension DependencyValues {
	public var photoCapture: PhotoCaptureClient {
		get { self[PhotoCaptureClient.self] }
		set { self[PhotoCaptureClient.self] = newValue }
	}
}

// MARK: - Test Dependency Key

extension PhotoCaptureClient: TestDependencyKey {
	public static let previewValue = Self.happy
	public static let testValue = Self()
}

// MARK: - Mock Constants

private enum MockConstants {
	static let shortDelayNanoseconds: UInt64 = 5_000_000         // 5ms
	static let mediumDelayNanoseconds: UInt64 = 100_000_000      // 100ms
	static let captureDelayNanoseconds: UInt64 = 300_000_000     // 300ms
}

// MARK: - Mock Helpers

#if os(iOS)
private func _mockPreviewView() async -> PhotoCaptureClient.PreviewView {
	await MainActor.run { PhotoCaptureClient.PreviewView(view: UIView()) }
}
#else
private func _mockPreviewView() async -> PhotoCaptureClient.PreviewView {
	await MainActor.run { PhotoCaptureClient.PreviewView(view: NSView()) }
}
#endif

// MARK: - Mock Implementations

extension PhotoCaptureClient {
	/// All operations do nothing or return defaults. Event stream never emits.
	public static let noop = Self(
		startSession: { },
		stopSession: { },
		capturePhoto: { _ in Photo() },
		switchCamera: { _ in },
		setFlashMode: { _ in },
		focus: { _ in },
		setZoomFactor: { _ in },
		setVisualZoom: { _, _, _ in },
		requestAuthorization: { .authorized },
		authorizationStatus: { .authorized },
		events: { AsyncStream { _ in } },
		pixelBufferStream: { AsyncStream { _ in } },
		previewView: { await _mockPreviewView() },
		updateOverlays: { _ in }
	)

	/// Returns realistic mock data with small delays to simulate real behavior.
	public static let happy = Self(
		startSession: {
			try await Task.sleep(nanoseconds: MockConstants.mediumDelayNanoseconds)
		},
		stopSession: { },
		capturePhoto: { settings in
			try await Task.sleep(nanoseconds: MockConstants.captureDelayNanoseconds)
			return Photo(
				fileDataRepresentation: Data(repeating: 0xFF, count: 1024),
				photoDimensions: CGSize(width: 4032, height: 3024),
				timestamp: .now,
				isRawPhoto: false
			)
		},
		switchCamera: { _ in
			try await Task.sleep(nanoseconds: MockConstants.mediumDelayNanoseconds)
		},
		setFlashMode: { _ in },
		focus: { _ in },
		setZoomFactor: { _ in },
		setVisualZoom: { _, _, _ in },
		requestAuthorization: { .authorized },
		authorizationStatus: { .authorized },
		events: {
			AsyncStream { continuation in
				Task {
					try? await Task.sleep(nanoseconds: MockConstants.mediumDelayNanoseconds)
					continuation.yield(.sessionStarted)
				}
			}
		},
		pixelBufferStream: { AsyncStream { _ in } },
		previewView: { await _mockPreviewView() },
		updateOverlays: { _ in }
	)

	/// Throws errors for operations that can fail.
	public static let failing = Self(
		startSession: {
			throw PhotoCaptureClient.Error.notAuthorized
		},
		stopSession: { },
		capturePhoto: { _ in
			throw PhotoCaptureClient.Error.captureFailed("Mock capture failure")
		},
		switchCamera: { position in
			throw PhotoCaptureClient.Error.captureDeviceNotFound(position)
		},
		setFlashMode: { _ in },
		focus: { _ in
			throw PhotoCaptureClient.Error.focusModeNotSupported
		},
		setZoomFactor: { _ in
			throw PhotoCaptureClient.Error.zoomFactorOutOfRange(min: 1.0, max: 10.0)
		},
		setVisualZoom: { _, _, _ in },
		requestAuthorization: { .denied },
		authorizationStatus: { .denied },
		events: {
			AsyncStream { continuation in
				Task {
					try? await Task.sleep(nanoseconds: MockConstants.mediumDelayNanoseconds)
					continuation.yield(.sessionRuntimeError("Mock runtime error"))
					continuation.finish()
				}
			}
		},
		pixelBufferStream: { AsyncStream { _ in } },
		previewView: { await _mockPreviewView() },
		updateOverlays: { _ in }
	)
}
