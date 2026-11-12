#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreImage
    import CoreMedia
    import Foundation
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    // MARK: - Session Configuration

    extension MultiCamSessionDelegate {
        func configureSession(_ config: MultiCamClient.SessionConfiguration) throws {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                throw MultiCamClient.Error.multiCamNotSupported
            }

            let session = AVCaptureMultiCamSession()
            session.automaticallyConfiguresApplicationAudioSession = false
            do {
                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord,
                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
                )
                try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                onEvent?(.sessionError("Audio session setup failed: \(error.localizedDescription)"))
            }
            session.beginConfiguration()

            var addedCameras: [MultiCamClient.CameraID] = []

            for cameraID in config.cameras {
                let avPosition = cameraID.avPosition
                let deviceType = cameraID.avDeviceType

                guard let device = AVCaptureDevice.default(deviceType, for: .video, position: avPosition) else {
                    onEvent?(.sessionError("Camera \(cameraID.rawValue) not found, skipping"))
                    continue
                }

                guard let input = try? AVCaptureDeviceInput(device: device),
                    session.canAddInput(input)
                else {
                    onEvent?(.sessionError("Cannot add \(cameraID.rawValue) input, skipping"))
                    continue
                }
                session.addInput(input)

                let videoOutput = AVCaptureVideoDataOutput()
                let queue = DispatchQueue(label: "MultiCamDelegate.video.\(cameraID.rawValue)")
                videoQueues[cameraID] = queue
                videoOutput.setSampleBufferDelegate(self, queue: queue)
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]

                guard session.canAddOutput(videoOutput) else {
                    session.removeInput(input)
                    videoQueues.removeValue(forKey: cameraID)
                    onEvent?(.sessionError("Cannot add \(cameraID.rawValue) output, skipping"))
                    continue
                }
                session.addOutput(videoOutput)

                // FIX #5: Configure frame rate BEFORE cost check
                if let _ = try? device.lockForConfiguration() {
                    let maxSupported =
                        device.activeFormat.videoSupportedFrameRateRanges
                        .map { $0.maxFrameRate }
                        .max() ?? 30
                    let clampedFPS = min(Double(config.frameRate), maxSupported)
                    let timescale = CMTimeScale(clampedFPS)
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: timescale)
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: timescale)
                    device.unlockForConfiguration()
                }

                // Check hardware cost after adding this camera + frame rate
                if session.hardwareCost >= 1.0 {
                    var reduced = false

                    // Strategy 1: Try a lower-resolution format
                    if let _ = try? device.lockForConfiguration() {
                        let currentFormat = device.activeFormat
                        let formats = device.formats.filter { fmt in
                            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                            let currentDims = CMVideoFormatDescriptionGetDimensions(currentFormat.formatDescription)
                            return dims.width < currentDims.width && dims.height < currentDims.height
                                && fmt.isMultiCamSupported
                        }.sorted { a, b in
                            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                            return da.width * da.height > db.width * db.height
                        }

                        for format in formats {
                            device.activeFormat = format
                            if session.hardwareCost < 1.0 {
                                reduced = true
                                break
                            }
                        }
                        device.unlockForConfiguration()
                    }

                    // FIX #7: Strategy 2: Try reducing frame rate as fallback
                    if !reduced, session.hardwareCost >= 1.0 {
                        if let _ = try? device.lockForConfiguration() {
                            let fallbackFPS: [Double] = [24, 15, 10]
                            for fps in fallbackFPS {
                                let maxSupported =
                                    device.activeFormat.videoSupportedFrameRateRanges
                                    .map { $0.maxFrameRate }
                                    .max() ?? 30
                                let clamped = min(fps, maxSupported)
                                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
                                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
                                if session.hardwareCost < 1.0 {
                                    reduced = true
                                    break
                                }
                            }
                            device.unlockForConfiguration()
                        }
                    }

                    // Still over budget — remove this camera
                    if !reduced && session.hardwareCost >= 1.0 {
                        let cost = session.hardwareCost
                        session.removeOutput(videoOutput)
                        session.removeInput(input)
                        videoQueues.removeValue(forKey: cameraID)
                        onEvent?(
                            .sessionError(
                                "\(cameraID.rawValue) exceeds hardware budget (cost: \(String(format: "%.2f", cost))), skipped"
                            )
                        )
                        continue
                    }
                }

                cameraInputs[cameraID] = input
                videoOutputs[cameraID] = videoOutput
                outputToCameraID[ObjectIdentifier(videoOutput)] = cameraID
                addedCameras.append(cameraID)

                // Rotate to portrait + apply default stabilization
                if let connection = videoOutput.connection(with: .video) {
                    connection.videoRotationAngle = 90
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .standard
                    }
                }
            }

            // FIX #6: Don't commit an empty session
            guard !addedCameras.isEmpty else {
                throw MultiCamClient.Error.cameraSetNotSupported(config.cameras)
            }

            // Add audio (only if requested)
            if config.includeAudio, let audioDevice = AVCaptureDevice.default(for: .audio) {
                if let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                    session.canAddInput(audioInput)
                {
                    session.addInput(audioInput)
                }
                let audioOut = AVCaptureAudioDataOutput()
                audioOut.setSampleBufferDelegate(self, queue: audioQueue)
                if session.canAddOutput(audioOut) {
                    session.addOutput(audioOut)
                    self.audioOutput = audioOut
                }
            }

            session.commitConfiguration()

            lastHardwareCost = session.hardwareCost
            activeCameras = addedCameras
            self.multiCamSession = session

            let costStr = String(format: "%.2f", session.hardwareCost)
            print(
                "📹 [MULTI_CAM]: Session configured with \(addedCameras.count)/\(config.cameras.count) cameras, hardware cost: \(costStr)/1.00"
            )
            for cam in addedCameras {
                print("📹 [MULTI_CAM]:   ✓ \(cam.rawValue)")
            }
            let dropped = config.cameras.filter { !addedCameras.contains($0) }
            for cam in dropped {
                print("📹 [MULTI_CAM]:   ✗ \(cam.rawValue) (dropped)")
            }
        }
    }

    // MARK: - CameraID → AVFoundation Mapping

    extension MultiCamClient.CameraID {
        var avPosition: AVCaptureDevice.Position {
            switch self {
                case .frontWide: return .front
                default: return .back
            }
        }

        var avDeviceType: AVCaptureDevice.DeviceType {
            switch self {
                case .frontWide: return .builtInWideAngleCamera
                case .backWide: return .builtInWideAngleCamera
                case .backUltraWide: return .builtInUltraWideCamera
                case .backTelephoto: return .builtInTelephotoCamera
                default: return .builtInWideAngleCamera
            }
        }
    }
#endif
