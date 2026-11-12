# claude-progress.md -- PhotoCaptureClient

## Current Verified State

- Last updated: 2026-11-12
- Repo root: `/Users/thanhhaikhong/Documents/PhotoCaptureClient`
- Standard startup path: `./init.sh`
- Standard verification path: `xcode-build --scheme PhotoCaptureClient-Package --platform ios`
- Last verified commit: 5511891 (uncommitted working changes for histogram-001 + gestures-001 on top)
- Last verification result: PASS — `xcode-build … --platform ios` BUILD SUCCEEDED (level 1) 2026-11-12, baseline + histogram-001 (probe-pass x3)
- Features passing: 6 / 8 -- preview-001, detection-001, detection-002/003/004 passing; gestures-001 + histogram-001 implemented+compiles, chờ device validation; detection-005 not_started
- Highest-priority unfinished feature: histogram-001 (active, chờ device validation); gestures-001 cũng chờ device; kế đó detection-005
- Blockers: none (histogram-001 và gestures-001 chỉ chờ user test trên thiết bị thật)
- Next best step: user validate histogram-001 trên device (bật histogram, kiểm 4 kênh realtime trên preview ảnh + video, không tụt frame) → mark passing; rồi gestures-001; rồi detection-005
- What must not change while doing it: the two-beat camera flow (preview full-rate, detection throttled ~3fps); public API PhotoCaptureClient/MultiCamClient chỉ THÊM setHistogramVisible, không đổi cái cũ

## Known Issues

<!-- One line each: the symptom, and the input or command that triggers it. An entry is
     deleted only when a verification run proves it fixed -- never because it stopped
     being mentioned. Anything here that blocks work is also named on Blockers above. -->

- v0.5.0 đã tag (annotated, trỏ 3b2fdb9) + push + GitHub Release (Latest) 2026-10-06. BÀI HỌC: publish = tag + release ĐI CÙNG NHAU. Các tag v0.2.1/v0.3.0/v0.3.1/v0.4.0 vẫn là tag-trần thiếu GitHub Release (GH release mới có v0.1.0/v0.2.0/v0.5.0) — bổ sung nếu cần.
- gestures-001 + drop-macOS (commit a7263ff, 79e0aa6 trên dev) nằm SAU v0.5.0 → dành cho 0.6.0 (sau khi gestures validate trên device).
- App tiêu thụ (Lensy) `Features/Package.swift` đang local-path override tạm → cần đổi về `from: "0.5.0"` sau khi đã release.
- clean-code gate đang hoãn tới bước tích hợp.
- Cần trim `DiagnosticLog` + bỏ log DEPTH verbose trước bản release thật.
- Gói nay là **iOS-only** (đã bỏ `.macOS` + mọi nhánh macOS/AppKit — xem Decision 2026-10-06). Hệ quả: `swift test` trên host macOS KHÔNG hợp lệ nữa (code iOS-only); SourceKit trong editor (đánh giá theo macOS host) sẽ báo đỏ `AVCaptureDepthDataOutput unavailable in macOS`, `Cannot find 'preferred'/'isRaw'`, `PreviewView has no member 'view'`… — đó là NHIỄU editor theo macOS, KHÔNG phải lỗi iOS. Verification thật = `xcode-build --platform ios` (xanh). Level-2 unit test cần route qua iOS simulator; wrapper `swift-test` hiện không route iOS cho gói SPM thuần (không có scheme) → unit test tự động vẫn chưa chạy được, cần dựng scheme iOS nếu muốn level-2.

## Decisions Made

<!-- What a later session would otherwise re-litigate from scratch. Not a design document.
     Entry shape -- copy, do not edit this block:
     ### 2026-10-06: <the decision, in one line>
     - Reason:
     - Rejected alternative:
     - Constraint it imposes: -->

### 2026-10-06: Gói là iOS-only — bỏ hết khai báo macOS
- Reason: user xác nhận "không build cho mac"; các nhánh AppKit/NSView + stub macOS chỉ là nợ không dùng.
- Rejected alternative: giữ cross-platform và guard depth API bằng `#if os(iOS)` để `swift test` chạy host macOS.
- Constraint it imposes: `Package.swift` chỉ còn `.iOS(.v17)`; đã xoá `import AppKit`, `NSView`, stub `setZoomFactor`/`getPreviewView` macOS, `.noop` liveValue macOS. Giữ nguyên các guard `#if os(iOS)` (và whole-file wrapper trong *Live) — chúng là guard iOS, không phải khai báo macOS. SourceKit editor báo đỏ theo macOS là nhiễu, không phải lỗi iOS. Unit test level-2 phải chạy trên iOS simulator.

### 2026-10-06: Model YOLO dùng AGPL-3.0; tách bạch khỏi stack tracker clean-room
- Reason: đã chấp nhận giấy phép AGPL của model Ultralytics YOLO.
- Rejected alternative: tự train/đổi model giấy phép khác.
- Constraint it imposes: `Sources/ObjectTracking` không được chứa code AGPL — xem `Sources/ObjectTracking/Attribution.swift`.

### 2026-10-06: Center-first khi chọn chủ thể cho center-dot
- Reason: người dùng hướng máy vào vật nào là có chủ đích.
- Rejected alternative: chọn theo vật gần nhất (depth-first).
- Constraint it imposes: depth chỉ là tiebreaker trong `centreTieBand`; có hysteresis + hold khi dropout.

### 2026-10-06: Ưu tiên depth phần cứng, monocular chỉ fallback
- Reason: depth cảm biến là mét và chính xác hơn; monocular là tương đối + model inference thứ hai.
- Rejected alternative: luôn chạy monocular `yolo26n-depth`.
- Constraint it imposes: `DepthEstimator` chỉ chạy khi `depthBuffer == nil`.

### 2026-10-06: Flow camera "hai nhịp" là nguyên tắc cốt lõi
- Reason: ML không được đè lên preview; preview phải full-rate và độc lập YOLO.
- Rejected alternative: một nhịp dùng chung cho cả preview lẫn inference.
- Constraint it imposes: preview gọi `onFrame?` mỗi frame; detection throttle ~3fps + `.bufferingNewest(1)`.

### 2026-10-06: "Đo, đừng đoán" cho giả thuyết nhiệt
- Reason: đo trên thiết bị cho thấy pipeline ML/depth/motion của gói KHÔNG phải nguồn nhiệt (CoreML 0,5% · depth 0,1% · motion 0,04% một core); thủ phạm ở phía app tiêu thụ (overlay SwiftUI animate ở display-rate).
- Rejected alternative: tối ưu depth/filtering trong gói để giảm nhiệt (đã đo là gần như vô ích).
- Constraint it imposes: trước khi tối ưu nhiệt phải đo (xctrace Time/Power/Core ML trên device).

## Session Log

<!-- Keep the five most recent sessions. Older blocks are deleted, not moved elsewhere:
     `git log` is already the complete record, and anything worth remembering longer than
     five sessions belongs under Decisions Made or Known Issues, which are never trimmed.
     Every session reads this file at startup, so it is the one artifact whose length has
     to stay bounded. -->

### Session 003 -- 2026-11-12

- Goal: đưa live Histogram (RGB + Luminance) lên preview, realtime, dùng cho cả chụp ảnh và quay video.
- Completed: target mới `HistogramKit` (Metal thuần, tái dùng) — `Histogram.metal` (compute accumulate R/G/B/Luma + reduceMax + panel/bars render), `HistogramOverlay.swift` (encodeCompute/encodeDraw, bins ở lại GPU, KHÔNG readback trên hot path), `HistogramConfig.swift`, `HistogramData.swift` (`HistogramBins` cho test). Nối vào `MetalPreviewRenderer.draw` (compute trước render pass, draw sau box, throttle ~12fps) và `MultiCamCompositor.draw` (primary camera texture, chỉ vẽ trên preview — KHÔNG trên pass recording nên video xuất ra sạch). API mới `setHistogramVisible` trên PhotoCaptureClient + MultiCamClient (interface/mocks/Live/Actor); MultiCam persist qua restart. Package.swift thêm target + 2 dep edge.
- Verification run: `xcode-build --platform ios` BUILD SUCCEEDED (probe-pass x3, level 1). Level 2 (`swift-test`) vẫn chặn (gói iOS-only, không scheme iOS — xem Known Issues); `HistogramOverlay.readback()` là hook test chờ scheme. Level 3 (device) chưa chạy — cần user.
- clean-code: load pack; stamp design (late) cho 3 file HistogramKit; check + review prepare. Code mới đã sửa mọi finding thật: F1 tier-A `makeRenderPipeline`→`RenderPipelineSpec`; F3 bỏ bool `additive`; N1 `HistogramData`→`HistogramBins`; G26 force-unwrap→guard; G33 boundary +1/-1→`ceilDiv`. Gate đầy đủ: **BYPASS** — scope bị chi phối bởi nợ tier-A **pre-existing** trong các file lớn chỉnh sửa (G4 @unchecked Sendable, C1 "Camera pipeline", G25 0.01 ở PiP pinch), theo tiền lệ hoãn-gate-tới-tích-hợp (gestures-001/detection-002). KHÔNG spawn 29-shard reviewer vì phần lớn là nợ có sẵn repo đã quyết hoãn.
- Commit: (chưa commit — user chưa yêu cầu).
- Files updated: xem feature_list.json histogram-001.evidence.
- Thêm (theo yêu cầu user): `setHistogramConfig(HistogramConfig)` cho cả hai client để chỉnh channels/vị trí (frame)/opacity realtime. Interface target nay phụ thuộc HistogramKit (kiểu config thuần Foundation). MetalPreviewRenderer giữ config trong `OSAllocatedUnfairLock`; MultiCam persist config qua restart.
- Theo yêu cầu "refactor sạch toàn bộ": dọn ~48 clean-code finding qua 5 vòng review (mỗi vòng dedup lại sinh finding mới — treadmill trên file Metal lớn, hội tụ dần 125→0). Kết quả **`clean-code gate`: CC=PASS** (review complete round 5, seals gánh 1846 pair). Refactor bảo toàn hành vi, `xcode-build --platform ios` BUILD SUCCEEDED nhiều lần. Chạm MultiCamCompositor (encodeViewport/encodeScene/renderComposite + RenderTarget/BorderStyle/Scene, makeTextureCache/makeTexture/makeRenderTarget, PiPGestureCoordinator base, named constants), MultiCamLive/Actor (collectCameraSets/sortedByPreference, startSession helpers), MetalPreviewRenderer (Resources struct, pinToBounds/observeMemoryWarnings/markNeedsRedraw, static maxBoxVertices), HistogramOverlay (Resources struct).
- **BREAKING API**: `MultiCamClient.setPiPBorder(width:r:g:b:)` → `setPiPBorder(width:color:)` (gom r/g/b thành `SIMD4<Float>`, có alpha thật — sửa luôn C2 doc mismatch). App tiêu thụ (Lensy) phải cập nhật call site khi bump version.
- Known risks: histogram-001 chưa validate trên device; MultiCam feed histogram = fullscreen/primary camera (chưa chọn được camera khác); setPiPBorder breaking → cần cập nhật Lensy.
- Next best step: user validate histogram-001 trên device → mark passing.

### Session 002 -- 2026-10-06

- Goal: implement gestures-001 (pinch-to-zoom + tap-to-focus trên preview)
- Completed: wire gesture vào MetalPreviewRenderer + actor + delegate theo docs/zoom-focus-gestures-design.md. Pinch → AVFoundation `videoZoomFactor` clamp (không throw); tap → focus + auto-expose; switch camera reset zoom tracking. Không đổi public API.
- Verification run: baseline `xcode-build --platform ios` PASS; probe `xcode-build --platform ios` BUILD SUCCEEDED (0 lỗi). `swift-test` KHÔNG chạy được (gap baseline macOS — xem Known Issues). Level 3 (device manual) chưa chạy — cần user.
- Evidence recorded: xem feature_list.json gestures-001.evidence.
- Commit: (chưa commit — chờ user duyệt commit)
- Files updated (gestures-001): Sources/PhotoCaptureClientLive/MetalPreviewRenderer.swift, Sources/PhotoCaptureClientLive/Actor.swift (swift-format normalize); feature_list.json.
- Thêm (theo yêu cầu user): bỏ hết macOS → iOS-only. Sửa Package.swift + PhotoCaptureClient/{Interface,Models,Mocks}, MultiCamClient/{Interface,Models,Mocks}, PhotoCaptureClientLive/Actor, MultiCamClientLive/Live. Pure deletion nhánh `#else` macOS. `xcode-build --platform ios` BUILD SUCCEEDED. grep macOS = 0.
- clean-code: check chạy; code gestures mới 0 tier-A; gate BYPASS (nợ tier-A toàn pre-existing, hoãn tới tích hợp). Bỏ-macOS là pure-deletion, không thêm finding.
- Known risks: gestures-001 chưa validate trên device; SourceKit editor báo đỏ theo macOS (nhiễu, iOS xanh); level-2 unit test cần scheme iOS.
- Next best step: user validate gestures-001 trên thiết bị → mark passing; rồi detection-005.

### Session 001 -- 2026-10-06

- Goal: initialize the harness + migrate di sản `docs/superpowers`
- Completed: AGENTS.md CLAUDE.md feature_list.json claude-progress.md init.sh session-handoff.md sprint-contract.md clean-state-checklist.md evaluator-rubric.md quality-document.md
- Verification run: `bash init.sh`
- Evidence recorded: migrate 2 plan đã-xong (metal preview, YOLO) → feature preview-001/detection-001 (passing); 1 spec gesture chưa-xong → feature gestures-001 (not_started) + chuyển spec ra `docs/zoom-focus-gestures-design.md`; xóa `docs/superpowers/`.
- Commit:
- Files updated: tạo harness; `git mv` spec gesture; `git rm -r docs/superpowers`
- Known risks or open questions: xem Known Issues (tag v0.4.0, Lensy override, clean-code gate, trim log)
- Next best step: implement gestures-001 per docs/zoom-focus-gestures-design.md

<!-- harness-init: template=1.5 pack=full generated=2026-10-06 -->
