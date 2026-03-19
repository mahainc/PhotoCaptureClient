#include <metal_stdlib>
using namespace metal;

// MARK: - Aspect-Fill Uniform

/// Passed from CPU to adjust texture coordinates for aspect-fill cropping.
struct AspectFillUniforms {
    float2 uvScale;   // Scale factor to crop the texture (> 1.0 means crop)
    float2 uvOffset;  // Offset to center the cropped region
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
    // Flip Y for top-left origin, then apply aspect-fill scale and offset
    float2 uv = float2(pos.x, 1.0 - pos.y);
    out.texCoord = uv * uniforms.uvScale + uniforms.uvOffset;
    return out;
}

fragment float4 cameraFragment(CameraVertexOut in [[stage_in]],
                                texture2d<float> cameraTexture [[texture(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                  address::clamp_to_edge);
    return cameraTexture.sample(texSampler, in.texCoord);
}

// MARK: - Bounding Box Overlay Rendering

struct BoxVertex {
    float2 position;
    float4 color;
};

struct BoxVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex BoxVertexOut boxVertex(uint vertexID [[vertex_id]],
                              const device BoxVertex* vertices [[buffer(0)]]) {
    BoxVertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 boxFragment(BoxVertexOut in [[stage_in]]) {
    return in.color;
}
