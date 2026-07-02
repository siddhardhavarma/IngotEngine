//
//  Math.swift
//  IngotEngine
//
//  Math helpers for 2D rendering: orthographic projection and transforms.
//

import simd

// ---------------------------------------------------------------------------
// Orthographic projection matrix
// ---------------------------------------------------------------------------
/// Creates a 4×4 orthographic projection matrix that maps a 2D pixel
/// coordinate system into Metal's normalized device coordinates (NDC).
///
///   (0, 0) = bottom-left of the screen
///   (width, height) = top-right of the screen
///
/// In column-major layout:
///
///   | 2/w    0     0    0 |
///   |  0    2/h    0    0 |
///   |  0     0     1    0 |
///   | -1    -1     0    1 |
///
func orthographicProjection(width: Float, height: Float) -> simd_float4x4 {
    return simd_float4x4(
        simd_float4(2.0 / width, 0,            0, 0),
        simd_float4(0,           2.0 / height,  0, 0),
        simd_float4(0,           0,             1, 0),
        simd_float4(-1,          -1,            0, 1)
    )
}

// ---------------------------------------------------------------------------
// 2D Translation matrix
// ---------------------------------------------------------------------------
/// Moves geometry by (tx, ty) pixels.
///
///   | 1   0   0   0 |
///   | 0   1   0   0 |
///   | 0   0   1   0 |
///   | tx  ty  0   1 |
///
func translationMatrix(tx: Float, ty: Float) -> simd_float4x4 {
    return simd_float4x4(
        simd_float4(1,  0,  0, 0),
        simd_float4(0,  1,  0, 0),
        simd_float4(0,  0,  1, 0),
        simd_float4(tx, ty, 0, 1)
    )
}

// ---------------------------------------------------------------------------
// 2D Rotation matrix (around the Z axis)
// ---------------------------------------------------------------------------
/// Rotates geometry by `angle` radians counter-clockwise around the origin.
///
///   | cos  sin  0  0 |
///   | -sin cos  0  0 |
///   |  0    0   1  0 |
///   |  0    0   0  1 |
///
/// In a 2D engine, "rotation" always means rotation around the Z axis,
/// because Z points out of the screen toward the viewer.
func rotationMatrix(angle: Float) -> simd_float4x4 {
    let c = cos(angle)
    let s = sin(angle)
    return simd_float4x4(
        simd_float4( c, s, 0, 0),
        simd_float4(-s, c, 0, 0),
        simd_float4( 0, 0, 1, 0),
        simd_float4( 0, 0, 0, 1)
    )
}

// ---------------------------------------------------------------------------
// 2D Scale matrix
// ---------------------------------------------------------------------------
/// Scales geometry by (sx, sy). Default (1, 1) means no scaling.
///
///   | sx  0   0  0 |
///   |  0  sy  0  0 |
///   |  0   0  1  0 |
///   |  0   0  0  1 |
///
func scaleMatrix(sx: Float, sy: Float) -> simd_float4x4 {
    return simd_float4x4(
        simd_float4(sx, 0,  0, 0),
        simd_float4(0,  sy, 0, 0),
        simd_float4(0,  0,  1, 0),
        simd_float4(0,  0,  0, 1)
    )
}
