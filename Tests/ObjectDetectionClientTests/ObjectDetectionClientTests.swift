import Dependencies
import XCTest
@testable import ObjectDetectionClient

final class ObjectDetectionClientTests: XCTestCase {
    func testDefaultModeIsManual() {
        withDependencies {
            $0.objectDetection = .noop
        } operation: {
            @Dependency(\.objectDetection) var client
            XCTAssertEqual(client.currentMode(), .manual)
        }
    }

    func testHappyPathStartDetection() async throws {
        try await withDependencies {
            $0.objectDetection = .happy
        } operation: {
            @Dependency(\.objectDetection) var client

            XCTAssertEqual(client.currentMode(), .auto)
            try await client.startDetection(.default)
        }
    }

    func testHappyPathDetectInImage() async throws {
        try await withDependencies {
            $0.objectDetection = .happy
        } operation: {
            @Dependency(\.objectDetection) var client

            let result = try await client.detectInImage(Data())
            XCTAssertFalse(result.objects.isEmpty)
            XCTAssertEqual(result.objects.first?.label, "cat")
            XCTAssertGreaterThan(result.objects.first?.confidence ?? 0, 0.9)
        }
    }

    func testNoopPath() async throws {
        try await withDependencies {
            $0.objectDetection = .noop
        } operation: {
            @Dependency(\.objectDetection) var client

            XCTAssertEqual(client.currentMode(), .manual)
            try await client.startDetection(.default)
            let result = try await client.detectInImage(Data())
            XCTAssertTrue(result.objects.isEmpty)
            await client.stopDetection()
        }
    }

    func testFailingPathStartDetection() async {
        await withDependencies {
            $0.objectDetection = .failing
        } operation: {
            @Dependency(\.objectDetection) var client

            do {
                try await client.startDetection(.default)
                XCTFail("Expected error")
            } catch {
                XCTAssertTrue(error is ObjectDetectionClient.Error)
            }
        }
    }

    func testFailingPathDetectInImage() async {
        await withDependencies {
            $0.objectDetection = .failing
        } operation: {
            @Dependency(\.objectDetection) var client

            do {
                _ = try await client.detectInImage(Data())
                XCTFail("Expected error")
            } catch {
                XCTAssertTrue(error is ObjectDetectionClient.Error)
            }
        }
    }

    func testConfigurationConvenience() {
        let defaultConfig = ObjectDetectionClient.Configuration.default
        XCTAssertEqual(defaultConfig.modelName, "yolo11n")
        XCTAssertEqual(defaultConfig.confidenceThreshold, 0.25)
        XCTAssertEqual(defaultConfig.maxDetections, 20)

        let fast = ObjectDetectionClient.Configuration.fast
        XCTAssertEqual(fast.confidenceThreshold, 0.5)
        XCTAssertEqual(fast.maxDetections, 10)

        let highAccuracy = ObjectDetectionClient.Configuration.highAccuracy
        XCTAssertEqual(highAccuracy.confidenceThreshold, 0.1)
        XCTAssertEqual(highAccuracy.maxDetections, 50)
    }

    func testDetectedObjectIdentifiable() {
        let id = UUID()
        let obj = ObjectDetectionClient.DetectedObject(
            id: id,
            label: "person",
            confidence: 0.9,
            boundingBox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
        XCTAssertEqual(obj.id, id)
    }

    func testBoundingBoxValues() {
        let box = ObjectDetectionClient.BoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(box.x, 0.1)
        XCTAssertEqual(box.y, 0.2)
        XCTAssertEqual(box.width, 0.3)
        XCTAssertEqual(box.height, 0.4)
    }

    func testErrorDescriptions() {
        let modelError = ObjectDetectionClient.Error.modelLoadFailed("not found")
        XCTAssertEqual(modelError.errorDescription, "Failed to load YOLO model: not found")

        let inferenceError = ObjectDetectionClient.Error.inferenceFailed("timeout")
        XCTAssertEqual(inferenceError.errorDescription, "Object detection inference failed: timeout")

        let modeError = ObjectDetectionClient.Error.invalidMode
        XCTAssertEqual(modeError.errorDescription, "Operation not available in current detection mode")

        let notRunning = ObjectDetectionClient.Error.notRunning
        XCTAssertEqual(notRunning.errorDescription, "Object detection is not running")
    }

    func testDetectionResultEquality() {
        let obj = ObjectDetectionClient.DetectedObject(
            label: "person",
            confidence: 0.9,
            boundingBox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )

        let result1 = ObjectDetectionClient.DetectionResult(objects: [obj])
        let result2 = ObjectDetectionClient.DetectionResult(objects: [obj])
        XCTAssertEqual(result1.objects, result2.objects)
    }
}
