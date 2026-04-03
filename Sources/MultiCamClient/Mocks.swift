import Dependencies
import Foundation
import PhotoCaptureClient
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Dependency Registration

extension DependencyValues {
	public var multiCam: MultiCamClient {
		get { self[MultiCamClient.self] }
		set { self[MultiCamClient.self] = newValue }
	}
}

// MARK: - Test Dependency Key

extension MultiCamClient: TestDependencyKey {
	public static let previewValue = Self.happy
	public static let testValue = Self()
}

// MARK: - Mock Constants

private enum MockConstants {
	static let shortDelayNanoseconds: UInt64 = 5_000_000         // 5ms
	static let mediumDelayNanoseconds: UInt64 = 100_000_000      // 100ms
	static let recordingDelayNanoseconds: UInt64 = 500_000_000   // 500ms
}

// MARK: - Mock Helpers

#if os(iOS)
private func _mockPreviewView() async -> MultiCamClient.PreviewView {
	await MainActor.run { MultiCamClient.PreviewView(view: UIView()) }
}
#else
private func _mockPreviewView() async -> MultiCamClient.PreviewView {
	await MainActor.run { MultiCamClient.PreviewView(view: NSView()) }
}
#endif

// MARK: - Mock Implementations

extension MultiCamClient {
	/// All operations do nothing or return defaults. Event stream never emits.
	public static let noop = Self(
		deviceCapability: {
			DeviceCapability(isMultiCamSupported: true, availableCameraSets: [[.frontWide, .backWide]], maxSimultaneousCameras: 2)
		},
		startSession: { _ in },
		stopSession: {},
		setLayout: { _ in },
		currentLayout: { .grid(.init()) },
		setZoom: { _, _ in },
		zoomRange: { _ in (1.0, 10.0) },
		startRecording: { _ in },
		pauseRecording: {},
		resumeRecording: {},
		stopRecording: { RecordingResult() },
		capturePhoto: { _ in PhotoCaptureClient.Photo() },
		requestAuthorization: { .authorized },
		authorizationStatus: { .authorized },
		events: { AsyncStream { _ in } },
		previewView: { await _mockPreviewView() },
		pixelBufferStream: { _ in AsyncStream { _ in } }
	)

	/// Returns realistic mock data with small delays to simulate real behavior.
	public static let happy = Self(
		deviceCapability: {
			DeviceCapability(
				isMultiCamSupported: true,
				availableCameraSets: [
					[.frontWide, .backWide],
					[.frontWide, .backUltraWide],
					[.backWide, .backUltraWide],
				],
				maxSimultaneousCameras: 2
			)
		},
		startSession: { _ in
			try await Task.sleep(nanoseconds: MockConstants.mediumDelayNanoseconds)
		},
		stopSession: {},
		setLayout: { _ in },
		currentLayout: { .grid(.init()) },
		setZoom: { _, _ in },
		zoomRange: { _ in (1.0, 15.0) },
		startRecording: { _ in
			try await Task.sleep(nanoseconds: MockConstants.shortDelayNanoseconds)
		},
		pauseRecording: {},
		resumeRecording: {},
		stopRecording: {
			try await Task.sleep(nanoseconds: MockConstants.recordingDelayNanoseconds)
			let tempDir = FileManager.default.temporaryDirectory
			return RecordingResult(
				combinedURL: tempDir.appendingPathComponent("mock-combined.mp4"),
				individualURLs: [
					.frontWide: tempDir.appendingPathComponent("mock-front.mp4"),
					.backWide: tempDir.appendingPathComponent("mock-back.mp4"),
				],
				duration: 15.0,
				timestamp: .now
			)
		},
		capturePhoto: { _ in
			PhotoCaptureClient.Photo(
				fileDataRepresentation: Data(repeating: 0xFF, count: 1024),
				photoDimensions: CGSize(width: 1920, height: 1080),
				timestamp: .now
			)
		},
		requestAuthorization: { .authorized },
		authorizationStatus: { .authorized },
		events: {
			AsyncStream { continuation in
				Task {
					try? await Task.sleep(nanoseconds: MockConstants.mediumDelayNanoseconds)
					continuation.yield(.sessionStarted)
					continuation.yield(.cameraConnected(.frontWide))
					continuation.yield(.cameraConnected(.backWide))
					continuation.finish()
				}
			}
		},
		previewView: { await _mockPreviewView() },
		pixelBufferStream: { _ in AsyncStream { _ in } }
	)

	/// Throws errors for operations that can fail.
	public static let failing = Self(
		deviceCapability: {
			DeviceCapability(isMultiCamSupported: false, availableCameraSets: [], maxSimultaneousCameras: 0)
		},
		startSession: { _ in
			throw MultiCamClient.Error.multiCamNotSupported
		},
		stopSession: {},
		setLayout: { _ in },
		currentLayout: { .grid(.init()) },
		setZoom: { _, _ in throw MultiCamClient.Error.sessionNotRunning },
		zoomRange: { _ in (1.0, 1.0) },
		startRecording: { _ in
			throw MultiCamClient.Error.sessionNotRunning
		},
		pauseRecording: {},
		resumeRecording: {},
		stopRecording: {
			throw MultiCamClient.Error.recordingNotInProgress
		},
		capturePhoto: { _ in throw MultiCamClient.Error.sessionNotRunning },
		requestAuthorization: { .denied },
		authorizationStatus: { .denied },
		events: {
			AsyncStream { continuation in
				Task {
					try? await Task.sleep(nanoseconds: MockConstants.mediumDelayNanoseconds)
					continuation.yield(.sessionError("Mock session error"))
					continuation.finish()
				}
			}
		},
		previewView: { await _mockPreviewView() },
		pixelBufferStream: { _ in AsyncStream { _ in } }
	)
}
