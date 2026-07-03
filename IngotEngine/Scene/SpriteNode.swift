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

    /// The asset file this sprite's texture came from (e.g. "hero.png"
    /// in the project's Assets/). Serialized with the scene so the
    /// editor and exported games can restore the texture on load.
    var textureName: String?

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

    // MARK: - Named animation playback (AnimationLibrary clips)

    /// Loads a texture for an asset file name. Injected by the platform
    /// shell (editor / exported game) so clip playback can swap sprite
    /// sheets without the engine knowing about GPUs. nil in headless
    /// runs — playback still updates textureName and UVs.
    static var textureResolver: ((String) -> MTLTexture?)?

    /// The animation character this sprite embodies (e.g. "Player").
    /// Clip lookups resolve within this character FIRST, so scripts on
    /// an attached sprite can just call playAnimation("run_left") even
    /// when other characters define a clip with the same name.
    /// Serialized with the scene.
    var characterName: String?

    /// The clip that auto-plays when the scene starts (e.g. "idle").
    /// Serialized with the scene.
    var defaultAnimationName: String?

    /// The clip currently playing, if any.
    private(set) var activeAnimation: AnimationClip?
    private var animationElapsed: Float = 0

    override init() {
        super.init()
        name = "Sprite"
    }

    /// Starts a named clip from the project's AnimationLibrary.
    /// Resolution order: the sprite's attached character's clip
    /// ("<characterName>/name"), then an exact qualified name
    /// ("Player/run_left"), then an unambiguous short name. If the
    /// clip carries its own sprite sheet, the sprite's texture swaps
    /// to it. Restarting the already-playing clip is a no-op (calling
    /// this every frame from a script is safe).
    override func playAnimation(_ name: String) {
        var resolved: AnimationClip?
        if let characterName, !characterName.isEmpty, !name.contains("/") {
            resolved = AnimationLibrary.clip(named: "\(characterName)/\(name)")
        }
        resolved = resolved ?? AnimationLibrary.clip(named: name)

        guard let clip = resolved else {
            Log.warning("Animation \"\(name)\" not found\(characterName.map { " (character: \($0))" } ?? "").")
            return
        }

        if let active = activeAnimation,
           active.qualifiedName == clip.qualifiedName { return }

        activeAnimation = clip
        animationElapsed = 0

        // The clip knows its sheet: switch to it so "run_left" always
        // animates over run_left.png, whatever the sprite showed before.
        if let sheet = clip.textureName, sheet != textureName {
            textureName = sheet
            if let resolved = SpriteNode.textureResolver?(sheet) {
                texture = resolved
            }
        }
    }

    /// Stops clip playback, keeping the current frame visible.
    override func stopAnimation() {
        activeAnimation = nil
        animationElapsed = 0
    }

    /// JS: node.character = "Player" — scopes playAnimation lookups.
    override var character: String {
        get { characterName ?? "" }
        set { characterName = newValue.isEmpty ? nil : newValue }
    }

    /// JS: if (node.currentAnimation != "run_left") node.playAnimation("run_left")
    override var currentAnimation: String {
        activeAnimation?.name ?? ""
    }

    override func ready() {
        super.ready()
        if let name = defaultAnimationName {
            playAnimation(name)
        } else if characterName != nil {
            showAnimationPreview()   // resting pose (idle) if one exists
        }
    }

    /// Shows the resting pose without running the game: resolves the
    /// default clip (or the attached character's "idle"), swaps to its
    /// sheet, and freezes on the first frame. The editor calls this in
    /// design mode — update() never runs there, so without it a sprite
    /// displays its recorded texture (often the raw sheet or older
    /// art) until Play starts.
    func showAnimationPreview() {
        var restingClip = defaultAnimationName
        if restingClip == nil, let characterName,
           AnimationLibrary.clip(named: "\(characterName)/idle") != nil {
            restingClip = "idle"
        }
        guard let name = restingClip else { return }

        playAnimation(name)
        if let clip = activeAnimation {
            let (column, row) = clip.gridPosition(frame: 0)
            setSpriteSheetFrame(gridWidth: clip.gridWidth, gridHeight: clip.gridHeight,
                                column: column, row: row)
        }
        stopAnimation()
    }

    override func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard isEnabled else { return }
        super.update(deltaTime: deltaTime, input: input)

        guard let clip = activeAnimation else { return }

        animationElapsed += Float(deltaTime)
        let rawFrame = Int(animationElapsed * max(clip.fps, 0.1))

        let frame: Int
        if clip.loops {
            frame = rawFrame % clip.frameCount
        } else {
            frame = min(rawFrame, clip.frameCount - 1)
            if rawFrame >= clip.frameCount {
                activeAnimation = nil
            }
        }

        let (column, row) = clip.gridPosition(frame: frame)
        setSpriteSheetFrame(gridWidth: clip.gridWidth, gridHeight: clip.gridHeight,
                            column: column, row: row)
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
