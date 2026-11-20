#include <metal_stdlib>
using namespace metal;

// MARK: - Aspect-Fill Uniform

/// Passed from CPU to adjust texture coordinates for aspect-fill cropping and zoom.
struct AspectFillUniforms {
    float2 uvScale;      // Scale factor to crop the texture (> 1.0 means crop)
    float2 uvOffset;     // Offset to center the cropped region
    float  zoomFactor;   // Visual zoom level (1.0 = no zoom, >1.0 = zoomed in)
    float  _pad;         // Padding for 16-byte alignment
    float2 zoomAnchor;   // Screen-space anchor point for zoom (0-1, top-left origin)
};

// MARK: - Camera Frame Rendering (fullscreen textured quad with aspect-fill)

struct CameraVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle that covers the viewport (no vertex buffer needed).
// Vertex IDs 0,1,2 produce a triangle larger than the screen; the rasterizer clips it.
vertex CameraVertexOut cameraVertex(uint vertexID [[vertex_id]],
                                     constant AspectFillUniforms& uniforms [[buffer(0)]]) {
    CameraVertexOut out;
    // Triangle covering [-1,-1] to [3,3] in clip space
    float2 pos = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    // Flip Y for top-left origin
    float2 uv = float2(pos.x, 1.0 - pos.y);
    // Apply zoom anchored at zoomAnchor in screen space
    uv = (uv - uniforms.zoomAnchor) / uniforms.zoomFactor + uniforms.zoomAnchor;
    // Then apply aspect-fill scale and offset
    out.texCoord = uv * uniforms.uvScale + uniforms.uvOffset;
    return out;
}

fragment float4 cameraFragment(CameraVertexOut in [[stage_in]],
                                texture2d<float> cameraTexture [[texture(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                  address::clamp_to_edge);
    return cameraTexture.sample(texSampler, in.texCoord);
}

/// A released still drawn over the returning camera, premultiplied by `opacity` as it fades out.
fragment float4 fadingStillFragment(CameraVertexOut in [[stage_in]],
                                    texture2d<float> still [[texture(0)]],
                                    constant float& opacity [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                  address::clamp_to_edge);
    return float4(still.sample(texSampler, in.texCoord).rgb * opacity, opacity);
}

// MARK: - Channel-Gain Filter (pure pixel transform)

/// Per-channel RGBA gain, applied once to produce the filtered texture that both the preview and
/// the histogram then read. `1` leaves a channel unchanged. This is the filter; measuring the
/// result is the histogram's separate job.
kernel void applyChannelGain(texture2d<float, access::read> source [[texture(0)]],
                             texture2d<float, access::write> destination [[texture(1)]],
                             constant float4& gain [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) {
        return;
    }
    destination.write(source.read(gid) * gain, gid);
}

// MARK: - Bounding Box Overlay Rendering

// `color` (16-byte aligned) is first so the layout has no padding (must match the Swift struct).
struct BoxVertex {
    float4 color;
    float2 position;   // Clip-space position (-1..1)
    float2 localPos;   // Pixel position within the box, relative to its center
    float2 halfSize;   // Box half-extent in pixels
    float2 params;     // x = corner radius (px), y = border width (px)
};

struct BoxVertexOut {
    float4 position [[position]];
    float4 color;
    float2 localPos;
    float2 halfSize;
    float2 params;
};

vertex BoxVertexOut boxVertex(uint vertexID [[vertex_id]],
                              const device BoxVertex* vertices [[buffer(0)]]) {
    BoxVertex v = vertices[vertexID];
    BoxVertexOut out;
    out.position = float4(v.position, 0.0, 1.0);
    out.color = v.color;
    out.localPos = v.localPos;
    out.halfSize = v.halfSize;
    out.params = v.params;
    return out;
}

// Signed distance from point `p` to a rounded rectangle centered at the origin.
// Negative inside, zero on the edge, positive outside.
float sdRoundBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - radius;
}

fragment float4 boxFragment(BoxVertexOut in [[stage_in]]) {
    float radius = in.params.x;
    float border = in.params.y;
    float dist = sdRoundBox(in.localPos, in.halfSize, radius);
    // Anti-alias over ~1px; the border ring is the band [-border, 0] of the SDF.
    float aa = max(fwidth(dist), 1e-4);
    float outer = 1.0 - smoothstep(-aa, aa, dist);
    float inner = 1.0 - smoothstep(-aa, aa, dist + border);
    float ring = clamp(outer - inner, 0.0, 1.0);
    float4 color = in.color;
    color.a *= ring;
    return color;
}

// MARK: - Text Overlay Rendering

// Must match `TextVertex` in PreviewUniforms.swift; `background` first so the layout has no padding.
struct TextVertex {
    float4 background;
    float2 position;   // Normalized camera-texture coordinates (top-left origin)
    float2 localPos;   // Pixels from the cover's center
    float2 halfSize;   // Cover half-extent in pixels
    float2 spriteUV;   // Text sprite coordinates; outside 0..1 there are no glyphs
    float2 params;     // x = corner radius (px), y = opacity
};

struct TextVertexOut {
    float4 position [[position]];
    float2 cameraUV;
    float4 background;
    float2 localPos;
    float2 halfSize;
    float2 spriteUV;
    float2 params;
};

// The inverse of cameraVertex's mapping, so text lands exactly on the pixels it was read from.
vertex TextVertexOut textVertex(uint vertexID [[vertex_id]],
                                const device TextVertex* vertices [[buffer(0)]],
                                constant AspectFillUniforms& uniforms [[buffer(1)]]) {
    TextVertex v = vertices[vertexID];
    float2 screen = (v.position - uniforms.uvOffset) / uniforms.uvScale;
    screen = (screen - uniforms.zoomAnchor) * uniforms.zoomFactor + uniforms.zoomAnchor;
    TextVertexOut out;
    out.position = float4(screen.x * 2.0 - 1.0, 1.0 - screen.y * 2.0, 0.0, 1.0);
    out.cameraUV = v.position;
    out.background = v.background;
    out.localPos = v.localPos;
    out.halfSize = v.halfSize;
    out.spriteUV = v.spriteUV;
    out.params = v.params;
    return out;
}

// Premultiplied output: glyphs over a rounded frosted cover (the blurred camera, tinted by
// `background`), both scaled by opacity.
// Small type is mostly anti-aliased edge, which reads gray on the dark cover; raising the
// coverage keeps the text's own color solid and the edges crisp.
constant float glyphCoverageGain = 1.6;

float4 solidGlyphs(float4 premultiplied) {
    float alpha = saturate(premultiplied.a * glyphCoverageGain);
    float3 color = premultiplied.a > 0.0 ? premultiplied.rgb / premultiplied.a : float3(0.0);
    return float4(color * alpha, alpha);
}

fragment float4 textFragment(TextVertexOut in [[stage_in]],
                             texture2d<float> sprite [[texture(0)]],
                             texture2d<float> backdrop [[texture(1)]]) {
    constexpr sampler spriteSampler(mag_filter::linear, min_filter::linear, address::clamp_to_zero);
    constexpr sampler backdropSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float dist = sdRoundBox(in.localPos, in.halfSize, in.params.x);
    float aa = max(fwidth(dist), 1e-4);
    float coverage = 1.0 - smoothstep(-aa, aa, dist);
    float3 frosted = mix(backdrop.sample(backdropSampler, in.cameraUV).rgb, in.background.rgb, in.background.a);
    float4 background = float4(frosted, 1.0) * coverage;
    float4 glyphs = solidGlyphs(sprite.sample(spriteSampler, in.spriteUV));
    return (glyphs + background * (1.0 - glyphs.a)) * in.params.y;
}
