#include <metal_stdlib>
using namespace metal;

// MARK: - Multi-Camera Uniforms

/// Per-camera uniforms for viewport-based rendering.
struct MultiCamUniforms {
    float4 viewportRect;   // (x, y, width, height) in normalized 0-1 space (top-left origin)
    float2 uvScale;        // Aspect-fill UV scale
    float2 uvOffset;       // Aspect-fill UV offset
    float  cornerRadius;   // Corner radius as fraction (0 = sharp)
    float  _pad1;          // Padding
    float2 _pad2;          // Pad to 48 bytes total (float4 alignment)
};

// MARK: - Camera Frame Rendering (quad — 4 vertices as triangle strip)

struct CameraVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 normalizedPos;  // Position within the viewport (0-1)
};

/// Renders a camera texture into a viewport rect using a quad (triangle strip, 4 vertices).
vertex CameraVertexOut multiCamVertex(uint vertexID [[vertex_id]],
                                       constant MultiCamUniforms& uniforms [[buffer(0)]]) {
    CameraVertexOut out;

    // Quad corners as triangle strip: TL, TR, BL, BR
    float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };

    float2 pos = corners[vertexID];

    // Map to viewport rect in clip space (-1 to 1, bottom-left origin)
    float2 vpOrigin = uniforms.viewportRect.xy;
    float2 vpSize = uniforms.viewportRect.zw;

    float clipX = (vpOrigin.x + pos.x * vpSize.x) * 2.0 - 1.0;
    float clipY = 1.0 - (vpOrigin.y + pos.y * vpSize.y) * 2.0;

    out.position = float4(clipX, clipY, 0.0, 1.0);

    // Texture coordinates with aspect-fill
    out.texCoord = pos * uniforms.uvScale + uniforms.uvOffset;
    out.normalizedPos = pos;

    return out;
}

fragment float4 multiCamFragment(CameraVertexOut in [[stage_in]],
                                  texture2d<float> cameraTexture [[texture(0)]],
                                  constant MultiCamUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                  address::clamp_to_edge);

    // Rounded rectangle SDF with correct inner-region handling
    float cornerRadius = uniforms.cornerRadius;
    if (cornerRadius > 0.0) {
        float2 p = in.normalizedPos;
        float2 center = float2(0.5, 0.5);
        float2 halfSize = float2(0.5, 0.5);

        // Scale corner radius by viewport aspect ratio for circular corners
        float vpAspect = uniforms.viewportRect.z / uniforms.viewportRect.w;
        float2 radius = float2(cornerRadius, cornerRadius * vpAspect);
        radius = min(radius, halfSize); // clamp to half-size

        float2 d = abs(p - center) - (halfSize - radius);
        // Full SDF: distance outside + distance inside (for correct flat edges)
        float dist = length(max(d, 0.0)) + min(max(d.x / radius.x, d.y / radius.y), 0.0) * min(radius.x, radius.y) - min(radius.x, radius.y);

        if (dist > 0.0) {
            discard_fragment();
        }
    }

    return cameraTexture.sample(texSampler, in.texCoord);
}
