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
}

let maxSpriteCount = 100

class ViewportViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var texture: MTLTexture!
    var instanceBuffer: MTLBuffer!

    /// Raw frame timestamp — used only to compute the deltaTime
    /// passed to engine.step(). The engine's GameClock handles
    /// clamping, scaling, and accumulation internally.
    private var lastFrameTime: CFTimeInterval = 0

    /// The engine is injected by the EditorViewController.
    /// The viewport reads from it but never creates it.
    var engine: Engine!

    // --- Mouse picking / dragging state ---

    private var draggedNode: SpriteNode?
    private var dragOffset = simd_float2(0, 0)
    private var lastVisibleSprites: [SpriteNode] = []

    // --- Callbacks to the editor shell ---

    var onNodePicked: ((SpriteNode?) -> Void)?
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

        let bufferSize = MemoryLayout<SpriteData>.stride * maxSpriteCount
        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            fatalError("Could not create instance buffer.")
        }
        instanceBuffer = buffer

        // NOTE: Scene creation has moved to EditorViewController.
        // The viewport only renders what the engine provides.
    }

    // MARK: - Keyboard input

    override var acceptsFirstResponder: Bool { true }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
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

        // If there's an active camera, reverse the view transform
        // to get from screen pixels back to world coordinates.
        if let camera = engine.currentScene?.activeCamera {
            let camPos = camera.globalTransform.columns.3
            let z = camera.zoom
            let sw = Float(metalView.drawableSize.width)
            let sh = Float(metalView.drawableSize.height)

            // Reverse: undo translate(screenCenter), undo scale(zoom), undo translate(-cam)
            screenX = (screenX - sw / 2) / z + camPos.x
            screenY = (screenY - sh / 2) / z + camPos.y
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

    override func mouseDown(with event: NSEvent) {
        // Re-claim keyboard focus so WASD keeps working after a click.
        view.window?.makeFirstResponder(self)

        let worldPos = convertToWorldSpace(event: event)
        let hitNode = pickNode(at: worldPos)

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
        guard let node = draggedNode else { return }

        let worldPos = convertToWorldSpace(event: event)
        node.position.x = worldPos.x - dragOffset.x
        node.position.y = worldPos.y - dragOffset.y

        onNodeDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        draggedNode = nil
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

    private func collectSpriteNodes(from node: Node, into result: inout [SpriteNode]) {
        guard node.isEnabled else { return }

        // Ensure dynamic textures are up-to-date for ShapeNode / TextNode.
        if let shape = node as? ShapeNode {
            shape.ensureTexture(device: device)
        } else if let text = node as? TextNode {
            text.ensureTexture(device: device)
        }

        if let sprite = node as? SpriteNode, sprite.texture != nil {
            result.append(sprite)
        }

        for child in node.children {
            collectSpriteNodes(from: child, into: &result)
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

        var visibleSprites: [SpriteNode] = []
        if let sceneRoot = engine.currentScene?.rootNode {
            collectSpriteNodes(from: sceneRoot, into: &visibleSprites)
        }
        lastVisibleSprites = visibleSprites

        let instanceCount = min(visibleSprites.count, maxSpriteCount)

        let instancePtr = instanceBuffer.contents().bindMemory(
            to: SpriteData.self, capacity: instanceCount
        )
        for i in 0..<instanceCount {
            instancePtr[i] = SpriteData(
                modelMatrix: visibleSprites[i].globalTransform,
                uvRect: visibleSprites[i].uvRect
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
        // Every vertex is then shifted by (-200, -100), which makes the
        // camera's position appear at the center of the screen.
        //
        // Zoom works similarly: zoom = 2.0 means everything is 2x bigger.
        // We scale the view by the zoom factor AFTER centering.
        //
        // The full formula:
        //   view = translate(screenW/2, screenH/2) × scale(zoom) × translate(-cx, -cy)
        //
        //   Step 1: translate(-cx, -cy) — center camera at origin
        //   Step 2: scale(zoom)         — magnify around center
        //   Step 3: translate(screenCenter) — map origin to screen center
        //
        //   viewProjection = projection × view
        //
        let projection = orthographicProjection(width: screenWidth, height: screenHeight)

        let viewMatrix: simd_float4x4
        if let camera = engine.currentScene?.activeCamera {
            let camPos = camera.globalTransform.columns.3
            let z = camera.zoom

            let centerOnCamera = translationMatrix(tx: -camPos.x, ty: -camPos.y)
            let applyZoom = scaleMatrix(sx: z, sy: z)
            let centerOnScreen = translationMatrix(tx: screenWidth / 2, ty: screenHeight / 2)

            viewMatrix = centerOnScreen * applyZoom * centerOnCamera
        } else {
            viewMatrix = matrix_identity_float4x4
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

        encoder.setFragmentTexture(texture, index: 0)

        encoder.drawPrimitives(type: .triangle,
                               vertexStart: 0,
                               vertexCount: vertices.count,
                               instanceCount: instanceCount)

        encoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()
    }
}
