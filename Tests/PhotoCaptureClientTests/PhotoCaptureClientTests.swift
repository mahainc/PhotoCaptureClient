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

    func testPreviewPerformanceModeIsCallable() async {
        await withDependencies {
            $0.photoCapture = .happy
        } operation: {
            @Dependency(\.photoCapture) var client
            await client.setPreviewPerformanceMode(.reduced)
            await client.setPreviewPerformanceMode(.full)
        }
    }

    func testExposureAndZoomRangesAreValid() async {
        await withDependencies {
            $0.photoCapture = .happy
        } operation: {
            @Dependency(\.photoCapture) var client

            let exposureRange = await client.exposureBiasRange()
            XCTAssertEqual(exposureRange, (-2.0)...(2.0))
            XCTAssertLessThan(exposureRange.lowerBound, exposureRange.upperBound)

            let zoomRange = await client.zoomFactorRange()
            XCTAssertEqual(zoomRange, 1.0...5.0)
            XCTAssertGreaterThanOrEqual(zoomRange.lowerBound, 1.0)
            XCTAssertLessThanOrEqual(zoomRange.upperBound, 10.0)
        }
    }

    func testHardwareControlSettersAreCallable() async throws {
        try await withDependencies {
            $0.photoCapture = .happy
        } operation: {
            @Dependency(\.photoCapture) var client

            try await client.setExposureBias(0.5)
            try await client.setWhiteBalanceKelvin(5500)
            try await client.setTorchLevel(0.0)
            try await client.setTorchLevel(0.7)
        }
    }

    func testHardwareControlSettersThrowOnFailingClient() async {
        await withDependencies {
            $0.photoCapture = .failing
        } operation: {
            @Dependency(\.photoCapture) var client

            let setters: [() async throws -> Void] = [
                { try await client.setExposureBias(1.0) },
                { try await client.setWhiteBalanceKelvin(6500) },
                { try await client.setTorchLevel(1.0) },
            ]
            for setter in setters {
                do {
                    try await setter()
                    XCTFail("Expected error")
                } catch {
                    XCTAssertTrue(error is PhotoCaptureClient.Error)
                }
            }

            // Range queries never throw, even on the failing client.
            let exposureRange = await client.exposureBiasRange()
            XCTAssertLessThan(exposureRange.lowerBound, exposureRange.upperBound)
            let zoomRange = await client.zoomFactorRange()
            XCTAssertLessThanOrEqual(zoomRange.upperBound, 10.0)
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
