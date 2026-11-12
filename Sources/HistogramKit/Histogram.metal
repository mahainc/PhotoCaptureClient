#include <metal_stdlib>
using namespace metal;

// MARK: - Shared Layout

// Bins are laid out channel-major: bins[channel * kBinCount + bin].
// Channel order is R, G, B, Luma — see HistogramChannelIndex in Swift.
constant uint kBinCount = 256;
constant float kLastBin = 255.0;
constant float3 kLumaCoefficients = float3(0.299, 0.587, 0.114);

// MARK: - Compute: Accumulate

/// Mirrors `AccumulateParams` in HistogramOverlay.swift.
struct AccumulateParams {
    uint sampleStride;
    uint width;
    uint height;
};

/// One thread per sampled pixel; atomically bumps the bin for each channel. The grid is
/// strided (every `sampleStride`-th pixel on each axis) to keep the pass cheap on the
/// preview's hot path.
kernel void histogramAccumulate(texture2d<float, access::read> source [[texture(0)]],
                                device atomic_uint *bins [[buffer(0)]],
                                constant AccumulateParams &params [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    uint2 coord = gid * params.sampleStride;
    if (coord.x >= params.width || coord.y >= params.height) {
        return;
    }
    float4 rgba = source.read(coord);
    float luma = dot(rgba.rgb, kLumaCoefficients);
    uint redBin = uint(clamp(rgba.r, 0.0, 1.0) * kLastBin + 0.5);
    uint greenBin = uint(clamp(rgba.g, 0.0, 1.0) * kLastBin + 0.5);
    uint blueBin = uint(clamp(rgba.b, 0.0, 1.0) * kLastBin + 0.5);
    uint lumaBin = uint(clamp(luma, 0.0, 1.0) * kLastBin + 0.5);
    atomic_fetch_add_explicit(&bins[0 * kBinCount + redBin], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[1 * kBinCount + greenBin], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[2 * kBinCount + blueBin], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[3 * kBinCount + lumaBin], 1, memory_order_relaxed);
}

// MARK: - Compute: Reduce Max

/// Folds every bin into a single global maximum so the draw can scale bars to fill their
/// frame regardless of exposure or sampled-pixel count.
kernel void histogramReduceMax(device const uint *bins [[buffer(0)]],
                               device atomic_uint *maxCount [[buffer(1)]],
                               constant uint &binTotal [[buffer(2)]],
                               uint index [[thread_position_in_grid]]) {
    if (index >= binTotal) {
        return;
    }
    atomic_fetch_max_explicit(maxCount, bins[index], memory_order_relaxed);
}

// MARK: - Render: Panel

/// Mirrors `QuadParams` in HistogramOverlay.swift. `frame` is a normalized view rect
/// (x, y, width, height) with a top-left origin.
struct QuadParams {
    float4 frame;
    float4 color;
};

struct QuadVertexOut {
    float4 position [[position]];
};

// Converts a normalized top-left view point (0..1) to clip space (-1..1, bottom-left).
static float2 viewToClip(float2 viewPoint) {
    return float2(viewPoint.x * 2.0 - 1.0, 1.0 - viewPoint.y * 2.0);
}

/// Draws `frame` as a flat quad (triangle strip of 4 corners) — the translucent backing
/// panel the channels sit on so they read over a bright live image.
vertex QuadVertexOut histogramPanelVertex(uint vertexID [[vertex_id]],
                                          constant QuadParams &params [[buffer(0)]]) {
    float2 corner = float2(float(vertexID & 1), float(vertexID >> 1));
    float2 view = params.frame.xy + corner * params.frame.zw;
    QuadVertexOut out;
    out.position = float4(viewToClip(view), 0.0, 1.0);
    return out;
}

fragment float4 histogramPanelFragment(constant QuadParams &params [[buffer(0)]]) {
    return float4(params.color.rgb * params.color.a, params.color.a);
}

// MARK: - Render: Bars

/// Mirrors `BarsParams` in HistogramOverlay.swift.
struct BarsParams {
    float4 frame;
    float4 color;
    uint channel;
    uint binCount;
    float _pad0;
    float _pad1;
};

struct BarsVertexOut {
    float4 position [[position]];
    float4 color;
};

/// Builds a filled area chart for one channel as a triangle strip: two vertices per bin
/// (baseline + bar top), heights normalized by the global max.
vertex BarsVertexOut histogramBarsVertex(uint vertexID [[vertex_id]],
                                         device const uint *bins [[buffer(0)]],
                                         device const uint *maxCount [[buffer(1)]],
                                         constant BarsParams &params [[buffer(2)]]) {
    uint bin = vertexID / 2;
    bool isTop = (vertexID & 1) == 1;
    float span = (params.binCount > 1) ? float(params.binCount - 1) : 1.0;
    float t = float(bin) / span;

    float maxValue = float(max(maxCount[0], 1u));
    float normalized = float(bins[params.channel * params.binCount + bin]) / maxValue;
    float barHeight = isTop ? normalized : 0.0;

    float2 view = float2(params.frame.x + t * params.frame.z,
                         params.frame.y + params.frame.w * (1.0 - barHeight));
    BarsVertexOut out;
    out.position = float4(viewToClip(view), 0.0, 1.0);
    out.color = params.color;
    return out;
}

fragment float4 histogramBarsFragment(BarsVertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}
