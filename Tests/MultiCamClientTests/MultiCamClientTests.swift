import Foundation
import Testing
import MultiCamClient

@Suite("MultiCamClient Models")
struct MultiCamClientModelTests {

	@Test("CameraID static values are distinct")
	func cameraIDDistinct() {
		let ids: Set<MultiCamClient.CameraID> = [.frontWide, .backWide, .backUltraWide, .backTelephoto]
		#expect(ids.count == 4)
	}

	@Test("CameraID is hashable and equatable")
	func cameraIDHashable() {
		let a = MultiCamClient.CameraID("test")
		let b = MultiCamClient.CameraID("test")
		#expect(a == b)
		#expect(a.hashValue == b.hashValue)
	}

	@Test("SessionConfiguration defaults")
	func sessionConfigDefaults() {
		let config = MultiCamClient.SessionConfiguration()
		#expect(config.cameras == [.frontWide, .backWide])
		#expect(config.preferredResolution == .hd1080p)
		#expect(config.frameRate == 30)
	}

	@Test("RecordingConfiguration defaults")
	func recordingConfigDefaults() {
		let config = MultiCamClient.RecordingConfiguration()
		#expect(config.outputMode == .combined)
		#expect(config.includeAudio == true)
		#expect(config.videoCodec == .h264)
	}

	@Test("PiPLayout clamps overlay scale")
	func pipLayoutClamp() {
		let pip = MultiCamClient.PiPLayout(overlayScale: 0.01) // below 0.1 minimum
		#expect(pip.overlayScale >= 0.1)

		let pip2 = MultiCamClient.PiPLayout(overlayScale: 0.9) // above 0.5 maximum
		#expect(pip2.overlayScale <= 0.5)
	}

	@Test("GridLayout enforces minimum 1 column")
	func gridMinColumns() {
		let grid = MultiCamClient.GridLayout(columns: 0)
		#expect(grid.columns == 1)
	}

	@Test("Layout convenience statics")
	func layoutConvenience() {
		let sideBySide = MultiCamClient.Layout.sideBySide
		if case .grid(let g) = sideBySide {
			#expect(g.columns == 2)
		} else {
			Issue.record("Expected grid layout")
		}

		let pip = MultiCamClient.Layout.standardPiP
		if case .pip(let p) = pip {
			#expect(p.primary == .backWide)
			#expect(p.overlay == .frontWide)
		} else {
			Issue.record("Expected pip layout")
		}
	}

	@Test("RecordingResult hasOutput")
	func recordingResultHasOutput() {
		let empty = MultiCamClient.RecordingResult()
		#expect(!empty.hasOutput)

		let withCombined = MultiCamClient.RecordingResult(
			combinedURL: URL(fileURLWithPath: "/tmp/test.mp4")
		)
		#expect(withCombined.hasOutput)
	}

	@Test("Error descriptions are non-empty")
	func errorDescriptions() {
		let errors: [MultiCamClient.Error] = [
			.multiCamNotSupported,
			.cameraSetNotSupported([.frontWide]),
			.sessionAlreadyRunning,
			.sessionNotRunning,
			.recordingAlreadyInProgress,
			.recordingNotInProgress,
			.recordingFailed("test"),
			.exportFailed("test"),
			.notAuthorized,
			.audioDeviceUnavailable,
		]
		for error in errors {
			#expect(error.errorDescription != nil)
			#expect(!error.errorDescription!.isEmpty)
		}
	}

	@Test("DeviceCapability default is unsupported")
	func deviceCapabilityDefault() {
		let cap = MultiCamClient.DeviceCapability()
		#expect(!cap.isMultiCamSupported)
		#expect(cap.availableCameraSets.isEmpty)
		#expect(cap.maxSimultaneousCameras == 0)
	}
}

@Suite("MultiCamClient Mocks")
struct MultiCamClientMockTests {

	@Test("Noop mock does not throw")
	func noopMock() async throws {
		let client = MultiCamClient.noop
		try await client.startSession(.init())
		await client.stopSession()
		await client.setLayout(.sideBySide)
		let layout = await client.currentLayout()
		#expect(layout == .grid(.init()))
	}

	@Test("Happy mock returns realistic data")
	func happyMock() async throws {
		let client = MultiCamClient.happy
		let cap = client.deviceCapability()
		#expect(cap.isMultiCamSupported)
		#expect(!cap.availableCameraSets.isEmpty)
	}

	@Test("Failing mock throws")
	func failingMock() async {
		let client = MultiCamClient.failing
		do {
			try await client.startSession(.init())
			Issue.record("Expected error")
		} catch {
			// Expected
		}
	}
}
