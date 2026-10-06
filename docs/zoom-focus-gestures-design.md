# Zoom + Focus Gestures Design (PhotoCaptureClient)

## Overview
Add default pinch-to-zoom and tap-to-focus to the camera preview without changing the public API. The gestures live in `MetalPreviewRenderer` (the preview UIView). The actor wires gesture callbacks to the existing AVFoundation delegate methods.

## Goals
- Pinch-to-zoom on the preview by default.
- Tap-to-focus (and auto-expose) at the tapped point.
- Correct coordinate mapping with aspect-fill and 90° rotation.
- No public API changes.

## Non-Goals
- No new UI indicators (focus box, zoom HUD).
- No programmatic zoom presets (e.g., double-tap to 2x).
- No public configuration flags.

## Architecture & Components

### MetalPreviewRenderer (UIView)
- Adds gesture recognizers:
  - `UIPinchGestureRecognizer` for zoom
  - `UITapGestureRecognizer` for focus
- Tracks zoom state:
  - `baseZoomFactor` (gesture anchor)
  - `currentZoomFactor`
  - `minZoomFactor` / `maxZoomFactor`
- Emits callbacks:
  - `onTapToFocus: (CGPoint) -> Void`
  - `onZoomChange: (CGFloat) -> Void`
- Converts tap coordinates to camera focus points using aspect-fill uniforms.

### PhotoCaptureClientActor
- Creates the renderer in `startSession()`.
- Supplies min/max zoom from current device.
- Wires renderer callbacks to the delegate:
  - `onTapToFocus` → `delegate.focusAndExpose(at:)`
  - `onZoomChange` → `delegate.smoothZoom(to:)`
- Resets zoom state on camera switch.
- Keeps renderer zoom state in sync when `setZoomFactor(_:)` is called programmatically.

### PhotoCaptureDelegate
- Adds focus + exposure method:
  - `focusAndExpose(at:)` (auto-focus + auto-expose at point)
- Adds `smoothZoom(to:)`:
  - Clamps to min/max.
  - Sets `device.videoZoomFactor` directly (gesture is already smooth).

## Data Flow

### Tap-to-Focus
1. User taps `MetalPreviewRenderer`.
2. Convert view point → normalized view (0..1).
3. Apply aspect-fill mapping (from shader):
   - `tex = uv * uvScale + uvOffset`
4. Convert portrait UV → AVFoundation focus point:
   - `focusX = texV`
   - `focusY = 1 - texU`
5. Delegate sets focus + exposure at that point.

### Pinch-to-Zoom
1. Pinch begins: `baseZoomFactor = currentZoomFactor`.
2. Pinch changes: `newZoom = baseZoomFactor * gesture.scale`.
3. Clamp to min/max.
4. Delegate sets `videoZoomFactor` to new value.

## Coordinate Conversion Details
The Metal shader uses:
```
texCoord = uv * uvScale + uvOffset
```
The video output is rotated 90° to portrait (`videoRotationAngle = 90`). The preview UV space is portrait (U: left→right, V: top→bottom). AVFoundation’s focus coordinates are landscape-left. Therefore:
- `focusX = texV`
- `focusY = 1 - texU`

Taps outside the visible area are clamped to [0, 1].

## Error Handling & Edge Cases
- If focus/exposure point is not supported, skip setting it.
- Zoom factor clamped to min/max.
- On camera switch, zoom resets to 1.0 and limits refresh.
- Front camera mirroring handled by AVFoundation; no extra transform.

## Testing & Validation
Manual validation:
1. Tap near each corner — focus follows expected spot.
2. Pinch in/out — zoom changes smoothly and clamps at limits.
3. Switch cameras — zoom resets to 1.0 and remains functional.

## Files to Change
- `Sources/PhotoCaptureClientLive/MetalPreviewRenderer.swift`
- `Sources/PhotoCaptureClientLive/Actor.swift`
- (No public API changes)
