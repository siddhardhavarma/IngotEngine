//
//  Shaders.metal
//  IngotEngine
//
//  Metal Shading Language (MSL) shaders for textured 2D rendering
//  with camera support, instanced batching, and UV atlas support.
//

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Uniforms — shared across ALL sprites, passed at [[buffer(1)]]
// ---------------------------------------------------------------------------
// Contains the combined view-projection matrix.
// This single matrix encodes:
//   1. The camera transform (pan + zoom) — the View matrix
//   2. The orthographic projection — pixel coords to NDC
//
// By combining them on the CPU, the shader only needs one matrix
// multiply per vertex instead of two.
struct Uniforms {
    float4x4 viewProjectionMatrix;
};

// ---------------------------------------------------------------------------
// SpriteData — one per sprite, passed as an array at [[buffer(2)]]
// ---------------------------------------------------------------------------
struct SpriteData {
    float4x4 modelMatrix;
    float4 uvRect;
};

// ---------------------------------------------------------------------------
// Vertex data structs
// ---------------------------------------------------------------------------

struct VertexIn {
    float2 position;
    float2 textureCoordinate;
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

// ---------------------------------------------------------------------------
// Vertex shader
// ---------------------------------------------------------------------------
/// Transforms each vertex through:
///   viewProjection × model × local → clip space
///
/// The viewProjectionMatrix already includes camera pan/zoom,
/// so all sprites shift together when the camera moves.
vertex VertexOut vertex_main(const device VertexIn* vertices [[buffer(0)]],
                             constant Uniforms& uniforms [[buffer(1)]],
                             const device SpriteData* instances [[buffer(2)]],
                             uint vid [[vertex_id]],
                             uint iid [[instance_id]]) {
    VertexOut out;

    float4 localPosition = float4(vertices[vid].position, 0.0, 1.0);

    out.position = uniforms.viewProjectionMatrix * instances[iid].modelMatrix * localPosition;

    float2 baseUV = vertices[vid].textureCoordinate;
    float4 uv = instances[iid].uvRect;
    out.textureCoordinate = uv.xy + baseUV * uv.zw;

    return out;
}

// ---------------------------------------------------------------------------
// Fragment shader
// ---------------------------------------------------------------------------
fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> texture [[texture(0)]]) {

    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);

    return texture.sample(textureSampler, in.textureCoordinate);
}
