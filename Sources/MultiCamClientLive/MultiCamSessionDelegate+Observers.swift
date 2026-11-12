#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreImage
    import CoreMedia
    import Foundation
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    // MARK: - Notification Observers & System Pressure KVO

    extension MultiCamSessionDelegate {
        func registerNotificationObservers() {
            let nc = NotificationCenter.default
            nc.addObserver(
                self,
                selector: #selector(sessionDidStartRunning),
                name: .AVCaptureSessionDidStartRunning,
                object: multiCamSession
            )
            nc.addObserver(
                self,
                selector: #selector(sessionDidStopRunning),
                name: .AVCaptureSessionDidStopRunning,
                object: multiCamSession
            )
            nc.addObserver(
                self,
                selector: #selector(sessionRuntimeError),
                name: .AVCaptureSessionRuntimeError,
                object: multiCamSession
            )
            nc.addObserver(
                self,
                selector: #selector(sessionWasInterrupted),
                name: .AVCaptureSessionWasInterrupted,
                object: multiCamSession
            )
            nc.addObserver(
                self,
                selector: #selector(sessionInterruptionEnded),
                name: .AVCaptureSessionInterruptionEnded,
                object: multiCamSession
            )

            // Observe system pressure on each active camera device
            for (cameraID, input) in cameraInputs {
                let observation = input.device.observe(\.systemPressureState, options: [.new]) {
                    [weak self] device, _ in
                    self?.handleSystemPressure(device: device, cameraID: cameraID)
                }
                pressureObservations.append(observation)
            }

            // Periodically report hardware cost
            if let session = multiCamSession {
                let costObservation = session.observe(\.hardwareCost, options: [.new]) { [weak self] session, _ in
                    let cost = session.hardwareCost
                    self?.lastHardwareCost = cost
                    self?.onEvent?(.hardwareCostUpdated(cost))
                }
                pressureObservations.append(costObservation)
            }
        }

        func removeNotificationObservers() {
            NotificationCenter.default.removeObserver(self)
            pressureObservations.removeAll()
        }

        private func handleSystemPressure(
            device: AVCaptureDevice,
            cameraID: MultiCamClient.CameraID
        ) {
            let pressureState = device.systemPressureState
            let level = pressureState.level.multiCamLevel

            onEvent?(.systemPressureChanged(level))

            // Auto-throttle on serious/critical pressure
            if pressureState.level == .serious {
                print("📹 [MULTI_CAM]: ⚠️ System pressure SERIOUS on \(cameraID.rawValue) — reducing frame rate")
                throttleDevice(device, targetFPS: 24)
            } else if pressureState.level == .critical {
                print("📹 [MULTI_CAM]: 🔴 System pressure CRITICAL on \(cameraID.rawValue) — reducing to minimum")
                throttleDevice(device, targetFPS: 15)
            } else if pressureState.level == .shutdown {
                print("📹 [MULTI_CAM]: 🛑 System pressure SHUTDOWN on \(cameraID.rawValue)")
                onEvent?(.sessionError("Device overheating — camera \(cameraID.rawValue) may stop"))
            }
        }

        private func throttleDevice(
            _ device: AVCaptureDevice,
            targetFPS: Double
        ) {
            guard let _ = try? device.lockForConfiguration() else { return }
            let maxSupported =
                device.activeFormat.videoSupportedFrameRateRanges
                .map { $0.maxFrameRate }
                .max() ?? 30
            let clamped = min(targetFPS, maxSupported)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
            device.unlockForConfiguration()
        }

        @objc private func sessionDidStartRunning(_ notification: Notification) {
            onEvent?(.sessionStarted)
        }

        @objc private func sessionDidStopRunning(_ notification: Notification) {
            onEvent?(.sessionStopped)
        }

        @objc private func sessionRuntimeError(_ notification: Notification) {
            let message: String
            if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
                message = error.localizedDescription
            } else {
                message = "Unknown runtime error"
            }
            onEvent?(.sessionError(message))
        }

        @objc private func sessionWasInterrupted(_ notification: Notification) {
            let reason: String
            if let userInfo = notification.userInfo,
                let rawReason = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int
            {
                switch AVCaptureSession.InterruptionReason(rawValue: rawReason) {
                    case .videoDeviceNotAvailableInBackground: reason = "App moved to background"
                    case .audioDeviceInUseByAnotherClient: reason = "Audio device in use by another app"
                    case .videoDeviceInUseByAnotherClient: reason = "Camera in use by another app"
                    case .videoDeviceNotAvailableWithMultipleForegroundApps:
                        reason = "Camera not available in split view"
                    case .videoDeviceNotAvailableDueToSystemPressure:
                        reason = "Camera unavailable due to system pressure"
                    default: reason = "Unknown interruption"
                }
            } else {
                reason = "Session interrupted"
            }
            onEvent?(.sessionInterrupted(reason))
        }

        @objc private func sessionInterruptionEnded(_ notification: Notification) {
            onEvent?(.sessionInterruptionEnded)
        }
    }

    // MARK: - System Pressure Level Mapping

    extension AVCaptureDevice.SystemPressureState.Level {
        var multiCamLevel: MultiCamClient.SystemPressureLevel {
            if self == .nominal { return .nominal }
            if self == .fair { return .fair }
            if self == .serious { return .serious }
            if self == .critical { return .critical }
            if self == .shutdown { return .shutdown }
            return .critical
        }
    }
#endif
