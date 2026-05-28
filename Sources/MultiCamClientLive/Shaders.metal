#include <metal_stdlib>
using namespace metal;

// MARK: - Multi-Camera Uniforms

/// Per-camera uniforms for viewport-based rendering.
/// Must match Swift struct `MultiCamUniforms` exactly (64 bytes).
struct MultiCamUniforms {
    float4 viewportRect;     // (x, y, width, height) in normalized 0-1 space
    float2 uvScale;          // Aspect-fill UV scale
    float2 uvOffset;         // Aspect-fill UV offset
    float  cornerRadius;     // Corner radius as fraction (0 = sharp, 0.5 = circle)
    float  borderWidth;      // Border width in normalized space (0 = no border)
    float4 borderColor;      // Border RGBA color
    float  pixelAspectRatio; // Viewport pixel width / pixel height
    float3 _pad;             // Pad to 80 bytes (float4 alignment)
};

// MARK: - Camera Frame Rendering

struct CameraVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 normalizedPos;  // Position within the viewport (0-1)
};

vertex CameraVertexOut multiCamVertex(uint vertexID [[vertex_id]],
                                       constant MultiCamUniforms& uniforms [[buffer(0)]]) {
    CameraVertexOut out;

    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };

    float2 pos = corners[vertexID];

    float2 vpOrigin = uniforms.viewportRect.xy;
    float2 vpSize = uniforms.viewportRect.zw;

    float clipX = (vpOrigin.x + pos.x * vpSize.x) * 2.0 - 1.0;
    float clipY = 1.0 - (vpOrigin.y + pos.y * vpSize.y) * 2.0;

    out.position = float4(clipX, clipY, 0.0, 1.0);
    out.texCoord = pos * uniforms.uvScale + uniforms.uvOffset;
    out.normalizedPos = pos;

    return out;
}

fragment float4 multiCamFragment(CameraVertexOut in [[stage_in]],
                                  texture2d<float> cameraTexture [[texture(0)]],
                                  constant MultiCamUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                  address::clamp_to_edge);

    float cornerRadius = uniforms.cornerRadius;
    float borderWidth = uniforms.borderWidth;
    float2 p = in.normalizedPos;

    // Compute distance from rounded rectangle edge in PIXEL space
    // Convert normalized position (0-1) to pixel coordinates within viewport
    float pixelAR = uniforms.pixelAspectRatio;
    float vpPixelW = uniforms.viewportRect.z * 1000.0; // arbitrary scale, ratio matters
    float vpPixelH = vpPixelW / pixelAR;

    float2 pixelPos = float2(p.x * vpPixelW, p.y * vpPixelH);
    float2 pixelCenter = float2(vpPixelW * 0.5, vpPixelH * 0.5);
    float2 pixelHalfSize = float2(vpPixelW * 0.5, vpPixelH * 0.5);

    // Corner radius in pixels: fraction of the smaller dimension
    float minDim = min(vpPixelW, vpPixelH);
    float radiusPixels = cornerRadius * minDim;

    // Unified rounded-rect SDF in shader-pixel space (axis-scaled by pixelAspectRatio
    // so the same physical-pixel border thickness is achieved on every edge). When r=0
    // this degrades cleanly to the standard axis-aligned rectangle SDF — using a single
    // formula avoids the previous asymmetric-border bug where the cornerRadius=0 branch
    // measured edge distance in unscaled normalized space and produced borders thicker
    // on the long axis of any non-square viewport.
    float r = min(radiusPixels, minDim * 0.5);
    float2 d = abs(pixelPos - pixelCenter) - (pixelHalfSize - r);
    float dist = length(max(d, 0.0)) - r;
    dist += min(max(d.x, d.y), 0.0);

    // Outside shape — discard
    if (dist > 0.5) {  // half-pixel tolerance for anti-aliasing
        discard_fragment();
    }

    // Anti-alias the edge
    if (dist > -0.5) {
        float4 texColor = cameraTexture.sample(texSampler, in.texCoord);
        float alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        if (borderWidth > 0.0) {
            return float4(uniforms.borderColor.rgb, alpha);
        }
        return float4(texColor.rgb, alpha * texColor.a);
    }

    // Border: solid color for pixels within borderWidth (in pixels) of the edge
    float borderPixels = borderWidth * min(vpPixelW, vpPixelH);
    if (borderPixels > 0.0 && dist > -borderPixels) {
        return uniforms.borderColor;
    }

    return cameraTexture.sample(texSampler, in.texCoord);
}
