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
        XCTAssertEqual(defaultConfig.modelName, "yolo26n")
        XCTAssertEqual(defaultConfig.confidenceThreshold, 0.25)
        XCTAssertEqual(defaultConfig.maxDetections, 10)
        XCTAssertNil(defaultConfig.dwellSeconds, "dwell cropping is opt-in")

        let fast = ObjectDetectionClient.Configuration.fast
        XCTAssertEqual(fast.confidenceThreshold, 0.5)
        XCTAssertEqual(fast.maxDetections, 10)

        let highAccuracy = ObjectDetectionClient.Configuration.highAccuracy
        XCTAssertEqual(highAccuracy.confidenceThreshold, 0.1)
        XCTAssertEqual(highAccuracy.maxDetections, 15)
    }

    /// `trackedSeconds` defaults to zero so a detection built without a tracker — the
    /// single-image path, and every caller that omits it — reports no history rather than
    /// an accidental age.
    func testDetectedObjectReportsNoAgeByDefault() {
        let object = ObjectDetectionClient.DetectedObject(
            label: "mug",
            confidence: 0.9,
            boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1)
        )
        XCTAssertEqual(object.trackedSeconds, 0)
    }

    /// The `dwelling` mock exists so dwell behaviour can be tested at all: `happy` mints a
    /// fresh `UUID` per emission, which makes every frame look like a new object and lets
    /// no age accumulate.
    func testDwellingMockHoldsOneIdentityAndMaturesOnce() async {
        let client = ObjectDetectionClient.dwelling(
            dwellSeconds: 1,
            frameInterval: 0.5,
            frames: 6
        )

        var ids: Set<UUID> = []
        var ages: [TimeInterval] = []
        var maturedIDs: [UUID] = []
        for await result in await client.detectionResults() {
            if let object = result.objects.first {
                ids.insert(object.id)
                ages.append(object.trackedSeconds)
            }
            maturedIDs.append(contentsOf: result.maturedObjects.map(\.id))
        }

        XCTAssertEqual(ids.count, 1, "one object held in view is one identity")
        XCTAssertEqual(ages, [0, 0.5, 1.0, 1.5, 2.0, 2.5], "age accumulates in real time")
        XCTAssertEqual(maturedIDs.count, 1, "an object matures once, however long it stays")
        XCTAssertEqual(maturedIDs.first, ids.first)
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
