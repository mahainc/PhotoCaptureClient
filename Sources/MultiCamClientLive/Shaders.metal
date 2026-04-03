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

// MARK: - Camera Frame Rendering

struct CameraVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 normalizedPos;  // Position within the viewport (0-1)
};

/// Renders a camera texture into a viewport rect.
/// vertexID 0,1,2 produces a fullscreen triangle; viewport transform maps it to the target rect.
vertex CameraVertexOut multiCamVertex(uint vertexID [[vertex_id]],
                                       constant MultiCamUniforms& uniforms [[buffer(0)]]) {
    CameraVertexOut out;

    // Fullscreen triangle covering [0,0] to [2,2] in UV space
    float2 pos = float2((vertexID << 1) & 2, vertexID & 2);

    // Map to viewport rect in clip space (-1 to 1, bottom-left origin)
    float2 vpOrigin = uniforms.viewportRect.xy;
    float2 vpSize = uniforms.viewportRect.zw;

    // Convert from 0-1 top-left origin to clip space (-1 to 1, bottom-left origin)
    float clipX = (vpOrigin.x + pos.x * vpSize.x) * 2.0 - 1.0;
    float clipY = 1.0 - (vpOrigin.y + pos.y * vpSize.y) * 2.0;

    out.position = float4(clipX, clipY, 0.0, 1.0);

    // Texture coordinates with aspect-fill
    float2 uv = float2(pos.x, pos.y);
    out.texCoord = uv * uniforms.uvScale + uniforms.uvOffset;
    out.normalizedPos = pos;

    return out;
}

fragment float4 multiCamFragment(CameraVertexOut in [[stage_in]],
                                  texture2d<float> cameraTexture [[texture(0)]],
                                  constant MultiCamUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                  address::clamp_to_edge);

    // Corner radius masking
    float cornerRadius = uniforms.cornerRadius;
    if (cornerRadius > 0.0) {
        float2 p = in.normalizedPos;
        float2 halfSize = float2(0.5, 0.5);
        float2 d = abs(p - halfSize) - (halfSize - cornerRadius);
        float dist = length(max(d, 0.0)) - cornerRadius;
        if (dist > 0.0) {
            discard_fragment();
        }
    }

    return cameraTexture.sample(texSampler, in.texCoord);
}

// MARK: - Background Fill

struct FillVertexOut {
    float4 position [[position]];
};

vertex FillVertexOut fillVertex(uint vertexID [[vertex_id]]) {
    FillVertexOut out;
    float2 pos = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

fragment float4 fillFragment(FillVertexOut in [[stage_in]]) {
    return float4(0.0, 0.0, 0.0, 1.0); // Black background
}
