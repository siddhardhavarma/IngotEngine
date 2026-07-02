//
//  ProjectExporter.swift
//  IngotEngine
//
//  §6 Export / Build Pipeline.
//
//  Exports the game project as a .swiftpm package targeting
//  iPhone, iPad, or Apple TV. The generated package contains:
//
//    MyGame.swiftpm/
//    ├── Package.swift           ← platform-specific manifest
//    └── Sources/
//        ├── App/
//        │   ├── GameApp.swift   ← SwiftUI @main
//        │   └── GameViewController.swift  ← Metal renderer
//        ├── Engine/             ← core engine files (copied)
//        ├── Resources/
//        │   ├── scene.json      ← serialized scene
//        │   ├── *.png, *.wav    ← assets
//        │   └── Scripts/        ← .js lifecycle files
//        └── Shaders/
//            └── Shaders.metal   ← GPU shaders
//

import Foundation

// ---------------------------------------------------------------------------
// Export Presets (§6)
// ---------------------------------------------------------------------------

/// The target platform for export.
enum ExportPlatform: String, CaseIterable {
    case iPhone  = "iPhone"
    case iPad    = "iPad"
    case appleTV = "Apple TV"

    var swiftPlatform: String {
        switch self {
        case .iPhone, .iPad: return ".iOS(.v17)"
        case .appleTV:       return ".tvOS(.v17)"
        }
    }

    var uiFramework: String {
        switch self {
        case .iPhone, .iPad: return "UIKit"
        case .appleTV:       return "UIKit"
        }
    }
}

/// Configuration for an export operation.
struct ExportPreset {
    var platform: ExportPlatform = .iPhone
    var gameName: String = "MyGame"
    var bundleID: String = "com.example.mygame"
    var designWidth: Int = 800
    var designHeight: Int = 600
}

// ---------------------------------------------------------------------------
// ProjectExporter
// ---------------------------------------------------------------------------

class ProjectExporter {

    /// Exports the game as a .swiftpm package.
    func exportProject(scene: Scene,
                       assetsDirectory: URL,
                       to destinationURL: URL,
                       preset: ExportPreset = ExportPreset()) throws {

        let fm = FileManager.default

        let sourcesApp = destinationURL.appendingPathComponent("Sources/App")
        let sourcesEngine = destinationURL.appendingPathComponent("Sources/Engine")
        let sourcesResources = destinationURL.appendingPathComponent("Sources/Resources")
        let sourcesScripts = destinationURL.appendingPathComponent("Sources/Resources/Scripts")
        let sourcesShaders = destinationURL.appendingPathComponent("Sources/Shaders")

        for dir in [sourcesApp, sourcesEngine, sourcesResources, sourcesScripts, sourcesShaders] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // --- 1. Package.swift ---
        try generatePackageManifest(preset: preset)
            .write(to: destinationURL.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)

        // --- 2. Scene data ---
        try SceneSerializer.serialize(scene)
            .write(to: sourcesResources.appendingPathComponent("scene.json"),
                   atomically: true, encoding: .utf8)

        // --- 3. Copy assets ---
        let assetExtensions = Set(["png", "jpg", "jpeg", "wav", "mp3", "aac"])
        copyFiles(from: assetsDirectory, to: sourcesResources,
                  extensions: assetExtensions, fm: fm)

        if let bundleResources = Bundle.main.resourceURL {
            copyFiles(from: bundleResources, to: sourcesResources,
                      extensions: assetExtensions, fm: fm)
        }

        // --- 4. Copy scripts ---
        if let scriptsDir = ProjectManager.shared.scriptsURL {
            copyFiles(from: scriptsDir, to: sourcesScripts,
                      extensions: Set(["js"]), fm: fm)
        }

        // --- 5. Copy Metal shaders ---
        if let metalURL = Bundle.main.url(forResource: "Shaders", withExtension: "metal") {
            try? fm.copyItem(at: metalURL, to: sourcesShaders.appendingPathComponent("Shaders.metal"))
        }

        // --- 6. Generate platform-specific app code ---
        try generateAppEntry(preset: preset)
            .write(to: sourcesApp.appendingPathComponent("GameApp.swift"),
                   atomically: true, encoding: .utf8)

        try generateGameViewController(preset: preset)
            .write(to: sourcesApp.appendingPathComponent("GameViewController.swift"),
                   atomically: true, encoding: .utf8)

        // --- 7. Generate a minimal engine stub ---
        try generateEngineStubs()
            .write(to: sourcesEngine.appendingPathComponent("EngineStubs.swift"),
                   atomically: true, encoding: .utf8)

        Log.info("Exported \(preset.gameName) for \(preset.platform.rawValue) to \(destinationURL.path)")
    }

    // MARK: - File copying

    private func copyFiles(from sourceDir: URL, to destDir: URL,
                            extensions: Set<String>, fm: FileManager) {
        guard let files = try? fm.contentsOfDirectory(at: sourceDir,
                                                       includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles) else { return }
        for file in files {
            if extensions.contains(file.pathExtension.lowercased()) {
                let dest = destDir.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: file, to: dest)
                }
            }
        }
    }

    // MARK: - Code generation

    private func generatePackageManifest(preset: ExportPreset) -> String {
        """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "\(preset.gameName)",
            platforms: [\(preset.platform.swiftPlatform)],
            targets: [
                .executableTarget(
                    name: "App",
                    path: "Sources",
                    resources: [
                        .copy("Resources")
                    ]
                )
            ]
        )
        """
    }

    private func generateAppEntry(preset: ExportPreset) -> String {
        """
        //  GameApp.swift — Auto-generated by Ingot Engine for \(preset.platform.rawValue)

        import SwiftUI

        @main
        struct \(preset.gameName.replacingOccurrences(of: " ", with: ""))App: App {
            var body: some Scene {
                WindowGroup {
                    GameViewRepresentable()
                        .ignoresSafeArea()
                }
            }
        }

        struct GameViewRepresentable: UIViewControllerRepresentable {
            func makeUIViewController(context: Context) -> GameViewController {
                GameViewController()
            }
            func updateUIViewController(_ vc: GameViewController, context: Context) {}
        }
        """
    }

    private func generateGameViewController(preset: ExportPreset) -> String {
        """
        //  GameViewController.swift — Auto-generated by Ingot Engine
        //  Target: \(preset.platform.rawValue)
        //
        //  Copy the engine's core Swift files into Sources/Engine/ to compile.

        import UIKit
        import MetalKit
        import simd

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

        class GameViewController: UIViewController, MTKViewDelegate {

            var device: MTLDevice!
            var commandQueue: MTLCommandQueue!
            var pipelineState: MTLRenderPipelineState!
            var instanceBuffer: MTLBuffer!
            private var lastFrameTime: CFTimeInterval = 0
            var engine = Engine()

            let vertices: [Vertex] = [
                Vertex(position: simd_float2(-50,  50), textureCoordinate: simd_float2(0, 0)),
                Vertex(position: simd_float2(-50, -50), textureCoordinate: simd_float2(0, 1)),
                Vertex(position: simd_float2( 50,  50), textureCoordinate: simd_float2(1, 0)),
                Vertex(position: simd_float2( 50,  50), textureCoordinate: simd_float2(1, 0)),
                Vertex(position: simd_float2(-50, -50), textureCoordinate: simd_float2(0, 1)),
                Vertex(position: simd_float2( 50, -50), textureCoordinate: simd_float2(1, 1)),
            ]

            override func viewDidLoad() {
                super.viewDidLoad()

                guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
                    fatalError("Metal is not supported on this device.")
                }
                device = defaultDevice

                let metalView = MTKView(frame: view.bounds, device: device)
                metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                metalView.clearColor = MTLClearColor(red: 0.392, green: 0.584, blue: 0.929, alpha: 1.0)
                metalView.delegate = self
                view.addSubview(metalView)

                commandQueue = device.makeCommandQueue()!
                buildPipeline(for: metalView)

                let bufferSize = MemoryLayout<SpriteData>.stride * maxSpriteCount
                instanceBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)!

                loadScene()
                engine.isPlaying = true
            }

            private func loadScene() {
                guard let url = Bundle.main.url(forResource: "scene", withExtension: "json",
                                                 subdirectory: "Resources"),
                      let json = try? String(contentsOf: url, encoding: .utf8),
                      let rootNode = SceneDeserializer.deserialize(jsonString: json) else {
                    print("Could not load scene.json")
                    return
                }

                let scene = Scene()
                scene.rootNode = rootNode

                SceneDeserializer.restoreActiveCamera(scene: scene, fromJSON: json)

                let loader = MTKTextureLoader(device: device)
                assignTextures(to: rootNode, loader: loader)

                engine.currentScene = scene
            }

            private func assignTextures(to node: Node, loader: MTKTextureLoader) {
                if let sprite = node as? SpriteNode, sprite.texture == nil {
                    if let tex = try? loader.newTexture(name: sprite.name,
                                                        scaleFactor: 1.0,
                                                        bundle: nil,
                                                        options: [.SRGB: false as NSNumber]) {
                        sprite.texture = tex
                    }
                }
                for child in node.children {
                    assignTextures(to: child, loader: loader)
                }
            }

            private func buildPipeline(for view: MTKView) {
                guard let library = device.makeDefaultLibrary(),
                      let vertexFn = library.makeFunction(name: "vertex_main"),
                      let fragmentFn = library.makeFunction(name: "fragment_main") else {
                    fatalError("Could not load shaders.")
                }

                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vertexFn
                desc.fragmentFunction = fragmentFn
                desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].rgbBlendOperation = .add
                desc.colorAttachments[0].alphaBlendOperation = .add
                desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelineState = try! device.makeRenderPipelineState(descriptor: desc)
            }

            func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

            func draw(in view: MTKView) {
                let now = CACurrentMediaTime()
                let rawDelta = Float(now - lastFrameTime)
                lastFrameTime = now

                let w = Float(view.drawableSize.width)
                let h = Float(view.drawableSize.height)

                engine.step(deltaTime: rawDelta)

                var visibleSprites: [SpriteNode] = []
                if let root = engine.currentScene?.rootNode {
                    collectSprites(from: root, into: &visibleSprites)
                }

                let count = min(visibleSprites.count, maxSpriteCount)
                let ptr = instanceBuffer.contents().bindMemory(to: SpriteData.self, capacity: count)
                for i in 0..<count {
                    ptr[i] = SpriteData(modelMatrix: visibleSprites[i].globalTransform,
                                        uvRect: visibleSprites[i].uvRect)
                }

                // Build view-projection matrix with camera support.
                let projection = orthographicProjection(width: w, height: h)
                let viewMatrix: simd_float4x4
                if let camera = engine.currentScene?.activeCamera {
                    let camPos = camera.globalTransform.columns.3
                    let z = camera.zoom
                    viewMatrix = translationMatrix(tx: w/2, ty: h/2)
                               * scaleMatrix(sx: z, sy: z)
                               * translationMatrix(tx: -camPos.x, ty: -camPos.y)
                } else {
                    viewMatrix = matrix_identity_float4x4
                }
                var uniforms = Uniforms(viewProjectionMatrix: projection * viewMatrix)

                guard let rpd = view.currentRenderPassDescriptor,
                      let cb = commandQueue.makeCommandBuffer(),
                      let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

                enc.setRenderPipelineState(pipelineState)
                enc.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                enc.setVertexBuffer(instanceBuffer, offset: 0, index: 2)

                if let tex = visibleSprites.first?.texture {
                    enc.setFragmentTexture(tex, index: 0)
                }

                if count > 0 {
                    enc.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: vertices.count, instanceCount: count)
                }

                enc.endEncoding()
                if let drawable = view.currentDrawable { cb.present(drawable) }
                cb.commit()
            }

            private func collectSprites(from node: Node, into result: inout [SpriteNode]) {
                guard node.isEnabled else { return }
                if let sprite = node as? SpriteNode, sprite.texture != nil {
                    result.append(sprite)
                }
                for child in node.children { collectSprites(from: child, into: &result) }
            }
        }
        """
    }

    /// Generates a minimal stub file explaining what engine files to copy.
    private func generateEngineStubs() -> String {
        """
        //  EngineStubs.swift — Auto-generated by Ingot Engine
        //
        //  IMPORTANT: Copy these files from the Ingot Engine project
        //  into this directory to compile the exported game:
        //
        //  From Core/:
        //    - Engine.swift, GameClock.swift, Math.swift
        //    - ProjectManager.swift (for script loading)
        //    - AssetHandle.swift, Log.swift, Tween.swift, FrameAnimation.swift
        //
        //  From Scene/:
        //    - Node.swift, SpriteNode.swift, CameraNode.swift, Scene.swift
        //    - ShapeNode.swift, TextNode.swift, AudioNode.swift, CollisionNode.swift
        //    - SceneDeserializer.swift
        //
        //  From Logic/:
        //    - Behavior.swift, ScriptBehavior.swift
        //    - Signal.swift, EventBus.swift
        //
        //  From Physics/:
        //    - PhysicsBody.swift, PhysicsWorld.swift
        //
        //  From Platform/:
        //    - InputManager.swift, AudioManager.swift, MusicPlayer.swift
        //
        //  From Core/ (JSExport):
        //    - Node+JSExport.swift
        //
        //  From Rendering/:
        //    - Shaders.metal (already in Sources/Shaders/)
        //
        //  A future version of Ingot Engine will copy these automatically.
        """
    }
}
