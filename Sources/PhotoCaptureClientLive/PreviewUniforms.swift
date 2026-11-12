#if os(iOS)
    import simd

    // MARK: - Aspect-Fill Uniforms (matches Metal struct layout)

    /// Must match `AspectFillUniforms` in Shaders.metal exactly.
    struct AspectFillUniforms {
        var uvScale: SIMD2<Float>
        var uvOffset: SIMD2<Float>
        var zoomFactor: Float
        var _pad: Float
        var zoomAnchor: SIMD2<Float>
    }

    // MARK: - Box Vertex (matches Metal struct layout)

    /// Must match `BoxVertex` in Shaders.metal exactly.
    /// `color` (SIMD4, 16-byte aligned) is first so there is no padding between fields.
    struct BoxVertex {
        var color: SIMD4<Float>
        var position: SIMD2<Float>
        /// Position within the box in pixels, relative to its center (for the SDF border).
        var localPos: SIMD2<Float>
        /// Box half-extent in pixels.
        var halfSize: SIMD2<Float>
        /// x = corner radius (px), y = border width (px).
        var params: SIMD2<Float>
    }
#endif
