# claude-progress.md -- PhotoCaptureClient

## Current Verified State

- Last updated: 2026-10-06
- Repo root: `/Users/thanhhaikhong/Documents/PhotoCaptureClient`
- Standard startup path: `./init.sh`
- Standard verification path: `xcode-build --scheme PhotoCaptureClient-Package --platform ios`
- Last verified commit: 3b2fdb9 (uncommitted working changes for gestures-001 on top)
- Last verification result: PASS — `xcode-build … --platform ios` BUILD SUCCEEDED (level 1) 2026-10-06, baseline + gestures-001
- Features passing: 6 / 7 -- preview-001, detection-001, detection-002/003/004 passing; gestures-001 implemented+compiles, chờ device validation; detection-005 not_started
- Highest-priority unfinished feature: gestures-001 (chờ manual device validation); kế đó detection-005 (param-type nợ structural)
- Blockers: none (gestures-001 chỉ chờ user test trên thiết bị thật)
- Next best step: user validate gestures-001 trên device (tap focus góc, pinch clamp, switch reset) → mark passing; sau đó detection-005
- What must not change while doing it: the two-beat camera flow (preview full-rate, detection throttled ~3fps); public API PhotoCaptureClient không đổi

## Known Issues

<!-- One line each: the symptom, and the input or command that triggers it. An entry is
     deleted only when a verification run proves it fixed -- never because it stopped
     being mentioned. Anything here that blocks work is also named on Blockers above. -->

- Chưa tag v0.4.0 + push PhotoCaptureClient (còn treo để phát hành).
- App tiêu thụ (Lensy) `Features/Package.swift` đang local-path override tạm → cần đổi về `from: "0.4.0"` sau khi tag.
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
