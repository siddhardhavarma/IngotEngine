//
//  SpriteNode.swift
//  IngotEngine
//
//  A Node subclass that can be rendered — it has a texture and a UV rect
//  that selects which region of the texture to display. This enables
//  texture atlases (sprite sheets) without changing the underlying texture.
//

import MetalKit
import simd

class SpriteNode: Node {

    /// The texture to draw on this sprite's quad.
    /// nil means the sprite won't be rendered (it's invisible).
    var texture: MTLTexture?

    /// The UV rectangle within the texture to display.
    ///
    ///   x = u_start   (0–1, left edge of the sub-region)
    ///   y = v_start   (0–1, top edge of the sub-region)
    ///   z = u_width   (0–1, width of the sub-region)
    ///   w = v_height  (0–1, height of the sub-region)
    ///
    /// Default (0, 0, 1, 1) shows the entire texture.
    var uvRect: simd_float4 = simd_float4(0, 0, 1, 1)

    /// RGBA tint multiplied over the texture (Godot's modulate).
    /// (1, 1, 1, 1) = unchanged; alpha < 1 fades the sprite out.
    var modulate = simd_float4(1, 1, 1, 1)

    /// Whether this sprite is currently showing a placeholder while
    /// waiting for a real texture to download.
    var isLoadingTexture: Bool = false

    override init() {
        super.init()
        name = "Sprite"
    }

    // MARK: - Sprite Sheet

    /// Sets the UV rect to display a single cell from a grid-based
    /// sprite sheet.
    ///
    /// Example: a 4×4 sprite sheet with 16 frames:
    ///
    ///   ┌─────┬─────┬─────┬─────┐
    ///   │ 0,0 │ 1,0 │ 2,0 │ 3,0 │  row 0
    ///   ├─────┼─────┼─────┼─────┤
    ///   │ 0,1 │ 1,1 │ 2,1 │ 3,1 │  row 1
    ///   ├─────┼─────┼─────┼─────┤
    ///   │ 0,2 │ 1,2 │ 2,2 │ 3,2 │  row 2
    ///   ├─────┼─────┼─────┼─────┤
    ///   │ 0,3 │ 1,3 │ 2,3 │ 3,3 │  row 3
    ///   └─────┴─────┴─────┴─────┘
    ///
    ///   setSpriteSheetFrame(gridWidth: 4, gridHeight: 4, column: 2, row: 1)
    ///   → uvRect = (0.5, 0.25, 0.25, 0.25) — the cell at column 2, row 1
    ///
    /// - Parameters:
    ///   - gridWidth:  Total number of columns in the sprite sheet.
    ///   - gridHeight: Total number of rows in the sprite sheet.
    ///   - column:     Which column (0-based, left to right).
    ///   - row:        Which row (0-based, top to bottom).
    func setSpriteSheetFrame(gridWidth: Int, gridHeight: Int, column: Int, row: Int) {
        let cellWidth = 1.0 / Float(gridWidth)
        let cellHeight = 1.0 / Float(gridHeight)
        let u = Float(column) * cellWidth
        let v = Float(row) * cellHeight
        uvRect = simd_float4(u, v, cellWidth, cellHeight)
    }

    /// Override the Node base implementation so JSC calls this version.
    /// Routes to setSpriteSheetFrame which updates the UV rect.
    override func setFrame(_ gridWidth: Int, _ gridHeight: Int, _ column: Int, _ row: Int) {
        setSpriteSheetFrame(gridWidth: gridWidth, gridHeight: gridHeight,
                            column: column, row: row)
    }

    // MARK: - Placeholder Texture

    private static var cachedPlaceholder: MTLTexture?
    private static var placeholderDevice: MTLDevice?

    static func placeholderTexture(device: MTLDevice) -> MTLTexture? {
        if let cached = cachedPlaceholder, placeholderDevice === device {
            return cached
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2, height: 2, mipmapped: false
        )
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        var pixels: [UInt8] = []
        for _ in 0..<4 {
            pixels.append(contentsOf: [160, 160, 160, 200])
        }
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: 8)

        cachedPlaceholder = texture
        placeholderDevice = device
        return texture
    }
}
