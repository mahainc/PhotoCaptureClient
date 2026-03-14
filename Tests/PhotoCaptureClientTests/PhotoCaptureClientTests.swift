import Dependencies
import XCTest
@testable import PhotoCaptureClient

final class PhotoCaptureClientTests: XCTestCase {
	func testHappyPath() async throws {
		try await withDependencies {
			$0.photoCapture = .happy
		} operation: {
			@Dependency(\.photoCapture) var client

			let status = await client.requestAuthorization()
			XCTAssertEqual(status, .authorized)

			try await client.startSession()

			let photo = try await client.capturePhoto(.default)
			XCTAssertTrue(photo.hasData)
			XCTAssertEqual(photo.photoDimensions, CGSize(width: 4032, height: 3024))
			XCTAssertFalse(photo.isRawPhoto)

			await client.stopSession()
		}
	}

	func testNoopPath() async throws {
		try await withDependencies {
			$0.photoCapture = .noop
		} operation: {
			@Dependency(\.photoCapture) var client

			let status = client.authorizationStatus()
			XCTAssertEqual(status, .authorized)

			try await client.startSession()
			let photo = try await client.capturePhoto(.default)
			XCTAssertFalse(photo.hasData)
			await client.stopSession()
		}
	}

	func testFailingPath() async {
		await withDependencies {
			$0.photoCapture = .failing
		} operation: {
			@Dependency(\.photoCapture) var client

			let status = client.authorizationStatus()
			XCTAssertEqual(status, .denied)

			do {
				try await client.startSession()
				XCTFail("Expected error")
			} catch {
				XCTAssertTrue(error is PhotoCaptureClient.Error)
			}

			do {
				_ = try await client.capturePhoto(.default)
				XCTFail("Expected error")
			} catch {
				XCTAssertTrue(error is PhotoCaptureClient.Error)
			}
		}
	}

	func testPhotoSettingsConvenience() {
		let defaultSettings = PhotoCaptureClient.PhotoSettings.default
		XCTAssertEqual(defaultSettings.flashMode, .auto)
		XCTAssertEqual(defaultSettings.qualityPrioritization, .balanced)

		let highQuality = PhotoCaptureClient.PhotoSettings.highQuality
		XCTAssertEqual(highQuality.qualityPrioritization, .quality)

		let fast = PhotoCaptureClient.PhotoSettings.fast
		XCTAssertEqual(fast.flashMode, .off)
		XCTAssertEqual(fast.qualityPrioritization, .speed)
	}
}
