# Hardware Cost Monitoring & Camera Maximization

## Overview

`AVCaptureMultiCamSession` has a hardware cost budget of **0.0–1.0**. Each camera input, video output, resolution, and frame rate consumes part of this budget. If the total exceeds 1.0, the session fails. Our system monitors cost in real time and gracefully degrades to maximize the number of active cameras.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                    App Layer                      │
│  AppStore.swift (TCA Reducer)                    │
│  - Requests cameras via selectedCameraSet        │
│  - Receives activeCameras (may be fewer)         │
└─────────────────────┬────────────────────────────┘
                      │
┌─────────────────────▼────────────────────────────┐
│              MultiCamClientActor                  │
│  Actor.swift                                     │
│  - queryCapability() → valid camera sets         │
│  - startSession() → passes actual cameras to     │
│    compositor and recording pipeline             │
└─────────────────────┬────────────────────────────┘
                      │
┌─────────────────────▼────────────────────────────┐
│           MultiCamSessionDelegate                 │
│  MultiCamSessionDelegate.swift                   │
│  - configureSession() → hardware cost monitoring │
│  - Cascade: Resolution → FPS → Remove camera     │
│  - Exposes: activeCameras, lastHardwareCost      │
└──────────────────────────────────────────────────┘
```

## Camera Discovery

Uses Apple's official `AVCaptureDevice.DiscoverySession.supportedMultiCamDeviceSets` API.

```swift
let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
    mediaType: .video,
    position: .unspecified  // both front and back
)
let validSets = discovery.supportedMultiCamDeviceSets  // [Set<AVCaptureDevice>]
```

**What this returns:** Sets of devices that can coexist. A set `{A, B, C}` means any 2 from that group work together — **not necessarily all 3 simultaneously**.

**What we do:** Keep full sets + extract all 2-camera pairs from larger sets. Sort by size descending. The session's greedy addition + cost monitoring determines the actual maximum.

### Camera ID Mapping

| CameraID | AVCaptureDevice.DeviceType | Position |
|----------|---------------------------|----------|
| `.frontWide` | `.builtInWideAngleCamera` | `.front` |
| `.backWide` | `.builtInWideAngleCamera` | `.back` |
| `.backUltraWide` | `.builtInUltraWideCamera` | `.back` |
| `.backTelephoto` | `.builtInTelephotoCamera` | `.back` |

## Session Configuration Flow

For each requested camera (in order):

```
1. Find device by type + position
   └─ Not found → skip, emit error event

2. Create AVCaptureDeviceInput + add to session
   └─ canAddInput false → skip

3. Create AVCaptureVideoDataOutput + add to session
   └─ canAddOutput false → remove input, skip

4. Configure frame rate (BEFORE cost check)
   └─ Clamp to device's max supported FPS

5. Check session.hardwareCost
   └─ < 1.0 → ✓ camera added successfully
   └─ >= 1.0 → enter remediation cascade:
       │
       ├─ Strategy 1: Lower resolution format
       │  Try smaller multi-cam-supported formats
       │  (sorted by area descending, prefer highest quality)
       │  └─ Cost < 1.0 → ✓ reduced, camera kept
       │
       ├─ Strategy 2: Lower frame rate
       │  Try 24 → 15 → 10 fps
       │  └─ Cost < 1.0 → ✓ reduced, camera kept
       │
       └─ Both failed → ✗ remove camera, log cost, continue
```

### Post-Configuration

```
6. Verify at least 1 camera added
   └─ Empty → throw .cameraSetNotSupported (no session committed)

7. Add audio input + output (if available)

8. Commit configuration

9. Record final state:
   - lastHardwareCost = session.hardwareCost
   - activeCameras = [cameras that passed]

10. Log results:
    📹 Session configured with 2/3 cameras, hardware cost: 0.87/1.00
    📹   ✓ back-wide
    📹   ✓ back-ultrawide
    📹   ✗ back-telephoto (dropped)
```

## Key Design Decisions

### 1. Frame rate before cost check
Frame rate significantly affects ISP bandwidth. Setting it before the cost check ensures the measurement reflects the actual load.

### 2. Greedy addition with priority
Cameras are added in array order. Earlier cameras get priority — they consume budget first. The app controls priority via the order of `selectedCameraSet`.

### 3. Cascade remediation (not immediate removal)
Before dropping a camera, we try:
1. Lower resolution (maintains FPS, reduces pixel throughput)
2. Lower FPS (maintains resolution, reduces frame throughput)

This maximizes camera count at the cost of some quality degradation.

### 4. Actual vs. Requested cameras
The Actor always uses `delegate.activeCameras` (not the requested set) for:
- **Compositor:** Only renders cameras that are actually streaming
- **Recording pipeline:** Only creates writers for active cameras
- **Pixel buffer streams:** Only yields from active cameras

This prevents black frames, empty recordings, and compositor mismatches.

### 5. No speculative "all cameras" set
We only show camera sets that the API explicitly returns as valid. We don't create a union of all devices and hope it works — that would lead to session failures.

## State Variables

| Variable | Type | Location | Purpose |
|----------|------|----------|---------|
| `lastHardwareCost` | `Float` | Delegate | Final cost after config (0.0–1.0) |
| `activeCameras` | `[CameraID]` | Delegate → Actor | Cameras that passed cost check |
| `availableCameraSets` | `[[CameraID]]` | DeviceCapability | Valid combos from discovery API |
| `maxSimultaneousCameras` | `Int` | DeviceCapability | Largest available set size |

## Error Handling

| Scenario | Error | Recovery |
|----------|-------|----------|
| All cameras dropped by cost | `.cameraSetNotSupported` | User selects fewer cameras |
| No active cameras when recording | `.cameraSetNotSupported([])` | Session restart needed |
| Individual camera skipped | Event: `.sessionError(msg)` | Other cameras continue |
| Multi-cam not supported | `.multiCamNotSupported` | Fall back to single lens |

## Bugs Fixed (v2)

| # | Severity | Bug | Fix |
|---|----------|-----|-----|
| 1 | HIGH | Compositor received requested cameras instead of actual | Uses `delegate.activeCameras` |
| 2 | MEDIUM | Speculative "all cameras" union could fail | Removed; only API-validated sets |
| 3 | MEDIUM | Recording started with 0 active cameras | Guard check added |
| 4 | MEDIUM | Compositor not updated after camera drops | Same fix as #1 |
| 5 | LOW | Frame rate set after cost check | Moved before cost check |
| 6 | LOW | Empty session committed on total failure | Guard before `commitConfiguration` |
| 7 | LOW | No frame rate fallback | Added 24→15→10 fps cascade |

## Device-Specific Notes

- **iPhone XS/XR:** 2 cameras max (front + back wide)
- **iPhone 11/12/13:** 2 cameras max (any combo from front, wide, ultrawide)
- **iPhone 14/15/16 Pro:** Potentially 3 cameras if hardware cost stays under 1.0 at reduced resolution/fps
- **iPad Pro:** Varies by generation

The actual maximum depends on chosen resolution and frame rate. Lower settings = more cameras fit in the budget.
