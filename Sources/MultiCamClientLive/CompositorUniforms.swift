#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import os

    // MARK: - Uniforms (must match Shaders.metal)

    /// Must match Metal struct `MultiCamUniforms` exactly (96 bytes).
    struct MultiCamUniforms {
        var viewportRect: SIMD4<Float>  // 16 bytes
        var uvScale: SIMD2<Float>  // 8 bytes
        var uvOffset: SIMD2<Float>  // 8 bytes
        var cornerRadius: Float  // 4 bytes
        var borderWidth: Float  // 4 bytes
        var borderColor: SIMD4<Float>  // 16 bytes
        var pixelAspectRatio: Float  // 4 bytes
        var _pad: SIMD3<Float>  // 12 bytes pad to 80
    }
#endif
