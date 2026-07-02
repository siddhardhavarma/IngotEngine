//
//  ShapeNode.swift
//  IngotEngine
//
//  §4.4 Scene System — Renders a colored shape without a texture file.
//
//  ShapeNode generates a solid-color 1×1 MTLTexture at runtime from
//  its `color` property. The existing sprite pipeline stretches this
//  across the quad, producing a colored rectangle. This avoids any
//  shader changes — a colored rect is just a 1-pixel texture scaled up.
//
//  Uses: UI panels, debug rectangles, solid backgrounds, platforms.
//

import MetalKit

class ShapeNode: SpriteNode {

    /// The fill color of this shape (RGBA, 0–1).
    var color: (r: Float, g: Float, b: Float, a: Float) = (1, 1, 1, 1) {
        didSet { needsTextureUpdate = true }
    }

    /// The width of the shape in pixels.
    var shapeWidth: Float = 100 {
        didSet { needsTextureUpdate = true }
    }

    /// The height of the shape in pixels.
    var shapeHeight: Float = 100 {
        didSet { needsTextureUpdate = true }
    }

    private var needsTextureUpdate = true
    private weak var cachedDevice: MTLDevice?

    override init() {
        super.init()
        name = "Shape"
    }

    /// Generates or updates the solid-color texture.
    /// Called lazily by the renderer before drawing.
    func ensureTexture(device: MTLDevice) {
        guard needsTextureUpdate || texture == nil || cachedDevice !== device else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .shaderRead

        guard let tex = device.makeTexture(descriptor: descriptor) else { return }

        let pixel: [UInt8] = [
            UInt8(min(max(color.r, 0), 1) * 255),
            UInt8(min(max(color.g, 0), 1) * 255),
            UInt8(min(max(color.b, 0), 1) * 255),
            UInt8(min(max(color.a, 0), 1) * 255),
        ]

        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0,
                    withBytes: pixel,
                    bytesPerRow: 4)

        texture = tex
        cachedDevice = device
        needsTextureUpdate = false

        // Scale the node so the quad matches the desired shape dimensions.
        // The base quad is 100×100 (±50), so scale = desired / 100.
        scale = simd_float2(shapeWidth / 100.0, shapeHeight / 100.0)
    }
}
