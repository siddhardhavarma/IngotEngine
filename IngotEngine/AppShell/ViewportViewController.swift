//
//  ViewportViewController.swift
//  IngotEngine
//
//  A pure renderer and input bridge. Owns Metal resources and the
//  draw loop, but does NOT own the Engine or Scene. The engine is
//  injected by the EditorViewController.
//
//  This class has two responsibilities:
//    1. Render: read engine.currentScene, build GPU buffers, draw.
//    2. Bridge: forward keyboard events to engine.input, forward
//       mouse events to the editor via callbacks.
//
//  Rendering model: the scene tree is flattened into RenderInstances
//  (sprites, tiles, particles), sorted by zIndex (stable — equal
//  zIndex keeps tree order), then drawn as instanced batches. A new
//  draw call starts only when the texture changes, so a whole tile
//  map or particle system still costs one draw call.
//

import Cocoa
import MetalKit
import simd

// ---------------------------------------------------------------------------
// GPU-side structs — must match Shaders.metal byte-for-byte
// ---------------------------------------------------------------------------
struct Vertex {
    var position: simd_float2
    var textureCoordinate: simd_float2
}

struct Uniforms {
    var viewProjectionMatrix: simd_float4x4
}

struct SpriteData {
    var modelMatrix: simd_float4x4
    var uvRect: simd_float4
    var color: simd_float4
}

// ---------------------------------------------------------------------------
// RenderInstance — one drawable quad, CPU-side
// ---------------------------------------------------------------------------
struct RenderInstance {
    var modelMatrix: simd_float4x4
    var uvRect: simd_float4
    var color: simd_float4
    var texture: MTLTexture?
    var zIndex: Int
}

class ViewportViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var texture: MTLTexture!
    var instanceBuffer: MTLBuffer!
    private var instanceCapacity = 256

    /// Raw frame timestamp — used only to compute the deltaTime
    /// passed to engine.step(). The engine's GameClock handles
    /// clamping, scaling, and accumulation internally.
    private var lastFrameTime: CFTimeInterval = 0

    /// The engine is injected by the EditorViewController.
    /// The viewport reads from it but never creates it.
    var engine: Engine!

    // --- Mouse picking / dragging state ---

    private var draggedNode: Node?
    private var dragOffset = simd_float2(0, 0)
    private var lastVisibleSprites: [SpriteNode] = []

    // --- Editor navigation (design mode only) ---
    //
    // In design mode the viewport uses its own camera, so users can
    // pan around a big level and zoom out to see everything without
    // touching the game's CameraNode. During Play the game camera
    // takes over. Scroll pans, pinch zooms, Cmd+0 resets.

    private var editorCenter = simd_float2(0, 0)
    private var editorZoom: Float = 1 {
        didSet { updateZoomLabel() }
    }
    private var editorViewInitialized = false

    // --- Editor overlay: grid, snapping, gizmos (design mode only) ---

    private static let gridVisibleKey = "IngotViewportGridVisible"
    private static let snapKey = "IngotViewportSnapEnabled"
    private static let gridSizeKey = "IngotViewportGridSize"

    private var showGrid = true
    private var snapToGrid = false
    private var gridSize: Float = 32

    /// 1×1 white texture tinted per-instance — grid lines, gizmo
    /// outlines, and selection highlights are all thin quads.
    private var whiteTexture: MTLTexture!

    /// Asks the editor shell which node is selected, so the viewport
    /// can draw a selection outline without owning selection state.
    var selectedNodeProvider: (() -> Node?)?

    // --- Overlay HUD bar (grid/snap/zoom controls) ---

    private var overlayBar: NSVisualEffectView!
    private var zoomLabel: NSTextField!
    private var coordsLabel: NSTextField!

    /// Re-centers the editor view on the game camera (or design center).
    func resetEditorView() {
        if let camera = engine.currentScene?.activeCamera {
            let position = camera.globalTransform.columns.3
            editorCenter = simd_float2(position.x, position.y)
        } else {
            editorCenter = simd_float2(400, 300)
        }
        editorZoom = 1
    }

    override func scrollWheel(with event: NSEvent) {
        guard !engine.isPlaying else { return }
        editorCenter.x -= Float(event.scrollingDeltaX) / editorZoom
        editorCenter.y += Float(event.scrollingDeltaY) / editorZoom
    }

    override func magnify(with event: NSEvent) {
        guard !engine.isPlaying else { return }
        editorZoom = min(max(editorZoom * (1 + Float(event.magnification)), 0.1), 8)
    }

    // --- Tile painting state ---

    /// When set, left-click/drag paints tiles on this map instead of
    /// picking/dragging nodes; right-click/drag erases. Controlled by
    /// the inspector's Paint Mode checkbox via the editor shell.
    var paintTarget: TileMapNode?

    /// The atlas tile index painted by the left mouse button.
    var paintTileIndex: Int = 0

    /// Fired once at the start of each paint stroke (for undo).
    var onPaintWillBegin: (() -> Void)?

    private var isPaintingStroke = false

    // --- Callbacks to the editor shell ---

    var onNodePicked: ((Node?) -> Void)?
    var onNodeDragMoved: (() -> Void)?
    var onDragWillBegin: (() -> Void)?

    private let quadHalfSize: Float = 50

    let vertices: [Vertex] = [
        Vertex(position: simd_float2(-50,  50), textureCoordinate: simd_float2(0, 0)),
        Vertex(position: simd_float2(-50, -50), textureCoordinate: simd_float2(0, 1)),
        Vertex(position: simd_float2( 50,  50), textureCoordinate: simd_float2(1, 0)),

        Vertex(position: simd_float2( 50,  50), textureCoordinate: simd_float2(1, 0)),
        Vertex(position: simd_float2(-50, -50), textureCoordinate: simd_float2(0, 1)),
        Vertex(position: simd_float2( 50, -50), textureCoordinate: simd_float2(1, 1)),
    ]

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this machine.")
        }
        device = defaultDevice

        let metalView = MTKView(frame: self.view.bounds, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.clearColor = MTLClearColor(red: 0.392, green: 0.584, blue: 0.929, alpha: 1.0)
        metalView.delegate = self
        self.view = metalView

        guard let queue = device.makeCommandQueue() else {
            fatalError("Could not create a Metal command queue.")
        }
        commandQueue = queue

        buildPipeline(for: metalView)
        loadTexture()
        makeWhiteTexture()

        makeInstanceBuffer(capacity: instanceCapacity)

        loadViewportPreferences()
        buildOverlayBar()

        // Live world-coordinate readout needs mouseMoved events.
        view.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))

        // NOTE: Scene creation has moved to EditorViewController.
        // The viewport only renders what the engine provides.
    }

    private func makeWhiteTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        whiteTexture = device.makeTexture(descriptor: descriptor)
        var pixel: [UInt8] = [255, 255, 255, 255]
        whiteTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                             mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    }

    private func loadViewportPreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.gridVisibleKey) != nil {
            showGrid = defaults.bool(forKey: Self.gridVisibleKey)
        }
        if defaults.object(forKey: Self.snapKey) != nil {
            snapToGrid = defaults.bool(forKey: Self.snapKey)
        }
        let storedSize = defaults.double(forKey: Self.gridSizeKey)
        if storedSize > 0 { gridSize = Float(storedSize) }
    }

    private func makeInstanceBuffer(capacity: Int) {
        let bufferSize = MemoryLayout<SpriteData>.stride * capacity
        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            fatalError("Could not create instance buffer.")
        }
        instanceBuffer = buffer
        instanceCapacity = capacity
    }

    /// Grows the instance buffer when a scene (tile maps, particles)
    /// needs more quads than the current capacity.
    private func ensureInstanceCapacity(_ needed: Int) {
        guard needed > instanceCapacity else { return }
        var capacity = instanceCapacity
        while capacity < needed { capacity *= 2 }
        makeInstanceBuffer(capacity: capacity)
    }

    // MARK: - Overlay HUD bar

    /// Floating control strip in the viewport's top-left corner:
    /// grid + snap toggles, grid size, zoom readout, reset view,
    /// and the mouse's live world coordinates.
    private func buildOverlayBar() {
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let gridCheck = NSButton(checkboxWithTitle: "Grid", target: self,
                                 action: #selector(gridToggled(_:)))
        gridCheck.state = showGrid ? .on : .off

        let snapCheck = NSButton(checkboxWithTitle: "Snap", target: self,
                                 action: #selector(snapToggled(_:)))
        snapCheck.state = snapToGrid ? .on : .off

        let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for size in [8, 16, 32, 64, 128] {
            sizePopup.addItem(withTitle: "\(size) px")
            sizePopup.lastItem?.tag = size
        }
        if !sizePopup.selectItem(withTag: Int(gridSize)) {
            _ = sizePopup.selectItem(withTag: 32)
        }
        sizePopup.target = self
        sizePopup.action = #selector(gridSizeChanged(_:))

        zoomLabel = makeBarLabel("100%")
        coordsLabel = makeBarLabel("x —  y —")

        let resetButton = NSButton(title: "Reset View", target: self,
                                   action: #selector(resetViewClicked))
        resetButton.bezelStyle = .accessoryBarAction

        for control in [gridCheck, snapCheck, sizePopup, resetButton] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: 11)
        }

        let stack = NSStackView(views: [gridCheck, snapCheck, sizePopup,
                                        zoomLabel, resetButton, coordsLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(stack)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
        ])

        overlayBar = bar
        updateZoomLabel()
    }

    private func makeBarLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func updateZoomLabel() {
        zoomLabel?.stringValue = "\(Int((editorZoom * 100).rounded()))%"
    }

    @objc private func gridToggled(_ sender: NSButton) {
        showGrid = sender.state == .on
        UserDefaults.standard.set(showGrid, forKey: Self.gridVisibleKey)
    }

    @objc private func snapToggled(_ sender: NSButton) {
        snapToGrid = sender.state == .on
        UserDefaults.standard.set(snapToGrid, forKey: Self.snapKey)
    }

    @objc private func gridSizeChanged(_ sender: NSPopUpButton) {
        gridSize = Float(max(sender.selectedTag(), 1))
        UserDefaults.standard.set(Double(gridSize), forKey: Self.gridSizeKey)
    }

    @objc private func resetViewClicked() {
        resetEditorView()
        view.window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard input

    override var acceptsFirstResponder: Bool { true }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+0: reset the editor view (like Xcode/Figma).
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "0" {
            resetEditorView()
            return
        }
        if !event.isARepeat {
            InputManager.shared.setKeyPressed(event.keyCode, isPressed: true)
        }
    }

    override func keyUp(with event: NSEvent) {
        InputManager.shared.setKeyPressed(event.keyCode, isPressed: false)
    }

    // MARK: - Mouse input

    func convertToWorldSpace(event: NSEvent) -> simd_float2 {
        guard let metalView = self.view as? MTKView else {
            return simd_float2(0, 0)
        }

        let viewPoint = metalView.convert(event.locationInWindow, from: nil)

        // Scale from view points to drawable pixels (Retina).
        let scaleX = Float(metalView.drawableSize.width / metalView.bounds.width)
        let scaleY = Float(metalView.drawableSize.height / metalView.bounds.height)

        var screenX = Float(viewPoint.x) * scaleX
        var screenY = Float(viewPoint.y) * scaleY

        let sw = Float(metalView.drawableSize.width)
        let sh = Float(metalView.drawableSize.height)

        // Reverse whichever view transform is active — the game camera
        // during Play, the editor camera in design mode.
        if engine.isPlaying, let camera = engine.currentScene?.activeCamera {
            let camPos = camera.globalTransform.columns.3
            let z = camera.zoom
            screenX = (screenX - sw / 2) / z + camPos.x
            screenY = (screenY - sh / 2) / z + camPos.y
        } else {
            screenX = (screenX - sw / 2) / editorZoom + editorCenter.x
            screenY = (screenY - sh / 2) / editorZoom + editorCenter.y
        }

        return simd_float2(screenX, screenY)
    }

    private func pickNode(at worldPos: simd_float2) -> SpriteNode? {
        for sprite in lastVisibleSprites.reversed() {
            let transform = sprite.globalTransform
            let centerX = transform.columns.3.x
            let centerY = transform.columns.3.y

            let halfW = quadHalfSize * abs(sprite.scale.x)
            let halfH = quadHalfSize * abs(sprite.scale.y)

            if worldPos.x >= centerX - halfW && worldPos.x <= centerX + halfW &&
               worldPos.y >= centerY - halfH && worldPos.y <= centerY + halfH {
                return sprite
            }
        }
        return nil
    }

    /// Picks nodes that are invisible in the game but drawn as gizmos
    /// in design mode: camera handles and trigger zones. Sprites get
    /// first claim (see mouseDown), so a large trigger zone can't
    /// swallow every click on the sprites inside it.
    private func pickGizmoNode(at worldPos: simd_float2) -> Node? {
        guard let root = engine.currentScene?.rootNode else { return nil }
        var hit: Node?
        forEachNode(root) { node in
            var half: simd_float2
            if node is CameraNode {
                half = simd_float2(14 / editorZoom, 14 / editorZoom)   // forgiving handle
            } else if let trigger = node as? CollisionNode {
                half = trigger.triggerSize / 2
            } else {
                return
            }
            let p = node.globalTransform.columns.3
            if abs(worldPos.x - p.x) <= half.x, abs(worldPos.y - p.y) <= half.y {
                hit = node
            }
        }
        return hit
    }

    private func forEachNode(_ node: Node, _ visit: (Node) -> Void) {
        guard node.isEnabled else { return }
        visit(node)
        for child in node.children { forEachNode(child, visit) }
    }

    // MARK: - Tile painting

    /// Converts a world position to the paint target's tile grid and
    /// sets/erases the tile there. Assumes the tile map is unrotated
    /// and unscaled (the same restriction as its collision).
    private func paintTile(at worldPos: simd_float2, erase: Bool) {
        guard let tileMap = paintTarget else { return }

        let origin = tileMap.globalTransform.columns.3
        let localX = worldPos.x - origin.x
        let localY = worldPos.y - origin.y
        let tx = Int(floor(localX / max(tileMap.tileWidth, 1)))
        let ty = Int(floor(localY / max(tileMap.tileHeight, 1)))

        tileMap.setTile(x: tx, y: ty, tileIndex: erase ? -1 : paintTileIndex)
    }

    private func beginPaintStrokeIfNeeded() {
        if !isPaintingStroke {
            isPaintingStroke = true
            onPaintWillBegin?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard paintTarget != nil else {
            super.rightMouseDown(with: event)
            return
        }
        beginPaintStrokeIfNeeded()
        paintTile(at: convertToWorldSpace(event: event), erase: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard paintTarget != nil else { return }
        paintTile(at: convertToWorldSpace(event: event), erase: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        isPaintingStroke = false
    }

    override func mouseDown(with event: NSEvent) {
        // Re-claim keyboard focus so WASD keeps working after a click.
        view.window?.makeFirstResponder(self)

        // Paint mode takes over the left mouse button entirely.
        if paintTarget != nil {
            beginPaintStrokeIfNeeded()
            paintTile(at: convertToWorldSpace(event: event), erase: false)
            return
        }

        let worldPos = convertToWorldSpace(event: event)
        var hitNode: Node? = pickNode(at: worldPos)
        if hitNode == nil, !engine.isPlaying {
            hitNode = pickGizmoNode(at: worldPos)
        }

        onNodePicked?(hitNode)

        if let node = hitNode {
            onDragWillBegin?()

            let nodeWorldX = node.globalTransform.columns.3.x
            let nodeWorldY = node.globalTransform.columns.3.y
            dragOffset = simd_float2(worldPos.x - nodeWorldX,
                                     worldPos.y - nodeWorldY)
            draggedNode = node
        } else {
            draggedNode = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if paintTarget != nil {
            paintTile(at: convertToWorldSpace(event: event), erase: false)
            return
        }

        guard let node = draggedNode else { return }

        let worldPos = convertToWorldSpace(event: event)
        var newX = worldPos.x - dragOffset.x
        var newY = worldPos.y - dragOffset.y

        if snapToGrid, !engine.isPlaying {
            let g = max(gridSize, 1)
            newX = (newX / g).rounded() * g
            newY = (newY / g).rounded() * g
        }

        node.position.x = newX
        node.position.y = newY

        onNodeDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        draggedNode = nil
        isPaintingStroke = false
    }

    override func mouseMoved(with event: NSEvent) {
        guard engine != nil, !engine.isPlaying, coordsLabel != nil else { return }
        let p = convertToWorldSpace(event: event)
        coordsLabel.stringValue = String(format: "x %.0f  y %.0f", p.x, p.y)
    }

    // MARK: - Pipeline & texture setup

    private func buildPipeline(for view: MTKView) {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load the default Metal shader library.")
        }
        guard let vertexFunction = library.makeFunction(name: "vertex_main") else {
            fatalError("Could not find vertex function 'vertex_main'.")
        }
        guard let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            fatalError("Could not find fragment function 'fragment_main'.")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Could not create render pipeline state: \(error)")
        }
    }

    func loadTexture() {
        let loader = MTKTextureLoader(device: device)

        do {
            texture = try loader.newTexture(name: "test_sprite",
                                            scaleFactor: 1.0,
                                            bundle: nil,
                                            options: [.SRGB: false])
        } catch {
            fatalError("Could not load texture 'test_sprite': \(error)")
        }
    }

    // MARK: - Scene tree traversal

    /// Flattens the scene tree into render instances. Sprites, tiles,
    /// and particles all become quads; each carries its own texture
    /// reference and modulate color.
    private func collectRenderInstances(from node: Node,
                                        into result: inout [RenderInstance],
                                        sprites: inout [SpriteNode]) {
        guard node.isEnabled else { return }

        // Ensure dynamic textures are up-to-date for ShapeNode / TextNode.
        if let shape = node as? ShapeNode {
            shape.ensureTexture(device: device)
        } else if let text = node as? TextNode {
            text.ensureTexture(device: device)
        }

        if let sprite = node as? SpriteNode, sprite.texture != nil {
            sprites.append(sprite)
            result.append(RenderInstance(
                modelMatrix: sprite.globalTransform,
                uvRect: sprite.uvRect,
                color: sprite.modulate,
                texture: sprite.texture,
                zIndex: sprite.zIndex
            ))
        }

        if let tileMap = node as? TileMapNode {
            let atlas = tileMap.texture ?? texture
            for (coord, tileIndex) in tileMap.tiles {
                result.append(RenderInstance(
                    modelMatrix: tileMap.modelMatrix(for: coord),
                    uvRect: tileMap.uvRect(forTileIndex: tileIndex),
                    color: simd_float4(1, 1, 1, 1),
                    texture: atlas,
                    zIndex: tileMap.zIndex
                ))
            }
        }

        if let particles = node as? ParticleNode {
            let particleTexture = ParticleNode.particleTexture(device: device)
            for particle in particles.particles {
                result.append(RenderInstance(
                    modelMatrix: particles.modelMatrix(of: particle),
                    uvRect: simd_float4(0, 0, 1, 1),
                    color: particles.color(of: particle),
                    texture: particleTexture,
                    zIndex: particles.zIndex
                ))
            }
        }

        for child in node.children {
            collectRenderInstances(from: child, into: &result, sprites: &sprites)
        }
    }

    // MARK: - Editor overlay geometry (design mode only)

    /// One tinted quad — grid lines, outlines, and fills are all
    /// instances of the 1×1 white texture (they batch into a single
    /// draw call at the end of the frame).
    private func gizmoQuad(cx: Float, cy: Float, w: Float, h: Float,
                           color: simd_float4) -> RenderInstance {
        RenderInstance(
            modelMatrix: translationMatrix(tx: cx, ty: cy)
                       * scaleMatrix(sx: w / 100, sy: h / 100),
            uvRect: simd_float4(0, 0, 1, 1),
            color: color,
            texture: whiteTexture,
            zIndex: 0
        )
    }

    private func appendOutline(cx: Float, cy: Float, halfX: Float, halfY: Float,
                               thickness: Float, color: simd_float4,
                               into overlay: inout [RenderInstance]) {
        overlay.append(gizmoQuad(cx: cx, cy: cy + halfY, w: halfX * 2 + thickness, h: thickness, color: color))
        overlay.append(gizmoQuad(cx: cx, cy: cy - halfY, w: halfX * 2 + thickness, h: thickness, color: color))
        overlay.append(gizmoQuad(cx: cx - halfX, cy: cy, w: thickness, h: halfY * 2 + thickness, color: color))
        overlay.append(gizmoQuad(cx: cx + halfX, cy: cy, w: thickness, h: halfY * 2 + thickness, color: color))
    }

    /// Half-extents of the selection outline for a node, by type.
    private func gizmoHalfExtents(of node: Node) -> simd_float2 {
        if let trigger = node as? CollisionNode { return trigger.triggerSize / 2 }
        if node is CameraNode { return simd_float2(11 / editorZoom, 11 / editorZoom) }
        if node is SpriteNode {
            return simd_float2(quadHalfSize * abs(node.scale.x),
                               quadHalfSize * abs(node.scale.y))
        }
        return simd_float2(14 / editorZoom, 14 / editorZoom)
    }

    /// Grid + axes, camera view-frame gizmo, trigger-zone gizmos, and
    /// the selection outline. Appended after the z-sorted scene so
    /// they always draw on top; never built during Play.
    private func buildEditorOverlay(screenWidth: Float, screenHeight: Float,
                                    into overlay: inout [RenderInstance]) {
        let halfW = screenWidth / (2 * editorZoom)
        let halfH = screenHeight / (2 * editorZoom)
        let minX = editorCenter.x - halfW
        let maxX = editorCenter.x + halfW
        let minY = editorCenter.y - halfH
        let maxY = editorCenter.y + halfH
        let px = 1 / editorZoom            // one screen pixel, in world units

        // --- Grid (coarsens as you zoom out: lines stay ≥ 12 px apart) ---
        if showGrid {
            var step = max(gridSize, 1)
            while step * editorZoom < 12 { step *= 2 }
            let gridColor = simd_float4(1, 1, 1, 0.07)

            var x = (minX / step).rounded(.down) * step
            while x <= maxX {
                if abs(x) > step * 0.01 {
                    overlay.append(gizmoQuad(cx: x, cy: editorCenter.y,
                                             w: px, h: halfH * 2, color: gridColor))
                }
                x += step
            }
            var y = (minY / step).rounded(.down) * step
            while y <= maxY {
                if abs(y) > step * 0.01 {
                    overlay.append(gizmoQuad(cx: editorCenter.x, cy: y,
                                             w: halfW * 2, h: px, color: gridColor))
                }
                y += step
            }

            // World axes, brighter, so the origin is always findable.
            if minY < 0, maxY > 0 {
                overlay.append(gizmoQuad(cx: editorCenter.x, cy: 0, w: halfW * 2, h: 2 * px,
                                         color: simd_float4(0.9, 0.35, 0.35, 0.4)))
            }
            if minX < 0, maxX > 0 {
                overlay.append(gizmoQuad(cx: 0, cy: editorCenter.y, w: 2 * px, h: halfH * 2,
                                         color: simd_float4(0.35, 0.9, 0.45, 0.4)))
            }
        }

        guard let scene = engine.currentScene else { return }

        // --- Node gizmos: camera frames + trigger zones ---
        let project = ProjectManager.shared.projectFile
        let designW = Float(project.designWidth)
        let designH = Float(project.designHeight)

        forEachNode(scene.rootNode) { node in
            if let camera = node as? CameraNode {
                let p = camera.globalTransform.columns.3
                let isActive = camera === scene.activeCamera
                let orange = simd_float4(1.0, 0.62, 0.15, isActive ? 0.9 : 0.45)

                // The view frame: exactly what the player sees at the
                // project's design resolution and this camera's zoom.
                if isActive {
                    let z = max(camera.zoom, 0.001)
                    appendOutline(cx: p.x, cy: p.y,
                                  halfX: designW / (2 * z), halfY: designH / (2 * z),
                                  thickness: 2 * px, color: orange, into: &overlay)
                }

                // The grab handle (click to select, drag to move).
                overlay.append(gizmoQuad(cx: p.x, cy: p.y, w: 22 * px, h: 22 * px,
                                         color: simd_float4(orange.x, orange.y, orange.z, 0.28)))
                appendOutline(cx: p.x, cy: p.y, halfX: 11 * px, halfY: 11 * px,
                              thickness: 1.5 * px, color: orange, into: &overlay)
            }

            if let trigger = node as? CollisionNode {
                let p = trigger.globalTransform.columns.3
                let half = trigger.triggerSize / 2
                overlay.append(gizmoQuad(cx: p.x, cy: p.y, w: half.x * 2, h: half.y * 2,
                                         color: simd_float4(0.25, 0.75, 1.0, 0.12)))
                appendOutline(cx: p.x, cy: p.y, halfX: half.x, halfY: half.y,
                              thickness: 1.5 * px,
                              color: simd_float4(0.25, 0.75, 1.0, 0.55), into: &overlay)
            }
        }

        // --- Selected tile map: make invisible collision visible ---
        // Transparent atlas cells paint perfectly invisible tiles, and
        // solid tiles collide as full squares regardless of their art.
        // Outline every painted cell faintly (so stray tiles can be
        // found and right-click-erased) and solid cells in red (the
        // actual colliders the player lands on).
        if let tileMap = (selectedNodeProvider?() as? TileMapNode) ?? paintTarget {
            let origin = tileMap.globalTransform.columns.3
            let halfTileX = tileMap.tileWidth / 2
            let halfTileY = tileMap.tileHeight / 2
            for (coord, index) in tileMap.tiles {
                let center = tileMap.tileCenter(coord)
                let cx = origin.x + center.x
                let cy = origin.y + center.y
                // Only the visible region — big maps stay cheap.
                if cx + halfTileX < minX || cx - halfTileX > maxX ||
                   cy + halfTileY < minY || cy - halfTileY > maxY { continue }

                if tileMap.solidTiles.contains(index) {
                    appendOutline(cx: cx, cy: cy,
                                  halfX: halfTileX - px, halfY: halfTileY - px,
                                  thickness: 1.5 * px,
                                  color: simd_float4(1.0, 0.3, 0.25, 0.55), into: &overlay)
                } else {
                    appendOutline(cx: cx, cy: cy,
                                  halfX: halfTileX - px, halfY: halfTileY - px,
                                  thickness: px,
                                  color: simd_float4(1, 1, 1, 0.14), into: &overlay)
                }
            }
        }

        // --- Selection outline ---
        if let selected = selectedNodeProvider?(), selected.isEnabled {
            let p = selected.globalTransform.columns.3
            let half = gizmoHalfExtents(of: selected)
            appendOutline(cx: p.x, cy: p.y,
                          halfX: half.x + 3 * px, halfY: half.y + 3 * px,
                          thickness: 2 * px,
                          color: simd_float4(1.0, 0.9, 0.25, 0.95), into: &overlay)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    func draw(in view: MTKView) {

        // --- Delta time (raw, unclamped — the engine's GameClock handles the rest) ---
        let currentTime = CACurrentMediaTime()
        let rawDelta = Float(currentTime - lastFrameTime)
        lastFrameTime = currentTime

        let screenWidth = Float(view.drawableSize.width)
        let screenHeight = Float(view.drawableSize.height)

        // --- Tick the engine (only runs if isPlaying) ---
        engine.step(deltaTime: rawDelta)

        // --- Render (always runs, even in design mode) ---
        // The viewport reads the scene tree and draws it regardless of
        // whether the engine is playing. This means you see your nodes
        // in the editor even when the game isn't running.

        var instances: [RenderInstance] = []
        var visibleSprites: [SpriteNode] = []
        if let sceneRoot = engine.currentScene?.rootNode {
            collectRenderInstances(from: sceneRoot, into: &instances, sprites: &visibleSprites)
        }
        lastVisibleSprites = visibleSprites

        // --- Z-order: stable sort by zIndex (equal z keeps tree order) ---
        var sorted = instances.enumerated()
            .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
            .map { $0.element }

        // --- Editor overlay: appended after the sort so grid/gizmos
        //     always draw on top. Design mode only — Play shows the
        //     clean game view. ---
        if overlayBar.isHidden != engine.isPlaying {
            overlayBar.isHidden = engine.isPlaying
        }
        if !engine.isPlaying {
            buildEditorOverlay(screenWidth: screenWidth, screenHeight: screenHeight,
                               into: &sorted)
        }

        let instanceCount = sorted.count
        ensureInstanceCapacity(instanceCount)

        let instancePtr = instanceBuffer.contents().bindMemory(
            to: SpriteData.self, capacity: max(instanceCount, 1)
        )
        for i in 0..<instanceCount {
            instancePtr[i] = SpriteData(
                modelMatrix: sorted[i].modelMatrix,
                uvRect: sorted[i].uvRect,
                color: sorted[i].color
            )
        }

        // --- Build the view-projection matrix ---
        //
        // THE VIEW MATRIX — WHY CAMERA RIGHT = VERTICES LEFT:
        //
        // A camera doesn't physically exist in the rendered image.
        // "Moving the camera right" means "show more of the world's
        // right side." The only way to achieve this is to shift all
        // vertices LEFT relative to the screen — the camera's motion
        // is simulated by moving the entire world in the OPPOSITE direction.
        //
        // Mathematically, the view matrix is the INVERSE of the camera's
        // world transform. If the camera is at (200, 100):
        //
        //   cameraTransform = translate(200, 100)
        //   viewMatrix      = translate(-200, -100)   ← inverse
        //
        // Zoom works similarly: zoom = 2.0 means everything is 2x bigger.
        // We scale the view by the zoom factor AFTER centering.
        //
        // The full formula:
        //   view = translate(screenW/2, screenH/2) × scale(zoom) × translate(-cx, -cy)
        //
        //   viewProjection = projection × view
        //
        let projection = orthographicProjection(width: screenWidth, height: screenHeight)

        // First frame: start the editor view where the game camera is.
        if !editorViewInitialized, engine.currentScene != nil {
            editorViewInitialized = true
            resetEditorView()
        }

        let viewMatrix: simd_float4x4
        if engine.isPlaying, let camera = engine.currentScene?.activeCamera {
            // Play mode: the game camera (with screen shake).
            let camPos = camera.globalTransform.columns.3
            let z = camera.zoom
            let cx = camPos.x + camera.shakeOffset.x
            let cy = camPos.y + camera.shakeOffset.y

            viewMatrix = translationMatrix(tx: screenWidth / 2, ty: screenHeight / 2)
                       * scaleMatrix(sx: z, sy: z)
                       * translationMatrix(tx: -cx, ty: -cy)
        } else {
            // Design mode: the editor's own pan/zoom.
            viewMatrix = translationMatrix(tx: screenWidth / 2, ty: screenHeight / 2)
                       * scaleMatrix(sx: editorZoom, sy: editorZoom)
                       * translationMatrix(tx: -editorCenter.x, ty: -editorCenter.y)
        }

        var uniforms = Uniforms(
            viewProjectionMatrix: projection * viewMatrix
        )

        guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)

        encoder.setVertexBytes(vertices,
                               length: MemoryLayout<Vertex>.stride * vertices.count,
                               index: 0)

        encoder.setVertexBytes(&uniforms,
                               length: MemoryLayout<Uniforms>.size,
                               index: 1)

        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)

        // --- Batched draws: one call per run of instances sharing a
        //     texture. baseInstance keeps [[instance_id]] aligned with
        //     the shared instance buffer. ---
        var batchStart = 0
        while batchStart < instanceCount {
            let batchTexture = sorted[batchStart].texture ?? texture
            var batchEnd = batchStart + 1
            while batchEnd < instanceCount && sorted[batchEnd].texture === sorted[batchStart].texture {
                batchEnd += 1
            }

            encoder.setFragmentTexture(batchTexture, index: 0)
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: 0,
                                   vertexCount: vertices.count,
                                   instanceCount: batchEnd - batchStart,
                                   baseInstance: batchStart)

            batchStart = batchEnd
        }

        encoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()
    }
}
