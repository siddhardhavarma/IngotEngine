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
//        │   ├── GameViewController.swift  ← Metal renderer
//        │   └── TouchControls.swift ← virtual joystick + action button
//        ├── Engine/             ← core engine files (auto-copied when
//        │                          the engine source path is known)
//        ├── Resources/
//        │   ├── scene.json      ← serialized scene
//        │   ├── *.png, *.wav    ← assets (also under Assets/)
//        │   ├── Scripts/        ← .js lifecycle files
//        │   └── Prefabs/        ← prefab JSON files
//        └── Shaders/
//            └── Shaders.metal   ← GPU shaders
//
//  Engine auto-copy: set the "IngotEngineSourcePath" user default to
//  the IngotEngine/ source directory (defaults write, or a future
//  settings UI) and the exporter copies every cross-platform engine
//  file into Sources/Engine/ so the package builds out of the box.
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

    /// Touch overlay only makes sense on touch screens.
    var supportsTouchControls: Bool {
        switch self {
        case .iPhone, .iPad: return true
        case .appleTV:       return false
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
        let sourcesAssets = destinationURL.appendingPathComponent("Sources/Resources/Assets")
        let sourcesScripts = destinationURL.appendingPathComponent("Sources/Resources/Scripts")
        let sourcesPrefabs = destinationURL.appendingPathComponent("Sources/Resources/Prefabs")
        let sourcesScenes = destinationURL.appendingPathComponent("Sources/Resources/Scenes")
        let sourcesShaders = destinationURL.appendingPathComponent("Sources/Shaders")

        for dir in [sourcesApp, sourcesEngine, sourcesResources, sourcesAssets,
                    sourcesScripts, sourcesPrefabs, sourcesScenes, sourcesShaders] {
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

        // --- 3. Copy assets (flat for bundle lookups, and under
        //        Assets/ for ProjectManager-style lookups) ---
        let assetExtensions = Set(["png", "jpg", "jpeg", "wav", "mp3", "aac"])
        copyFiles(from: assetsDirectory, to: sourcesResources,
                  extensions: assetExtensions, fm: fm)
        copyFiles(from: assetsDirectory, to: sourcesAssets,
                  extensions: assetExtensions, fm: fm)

        if let bundleResources = Bundle.main.resourceURL {
            copyFiles(from: bundleResources, to: sourcesResources,
                      extensions: assetExtensions, fm: fm)
        }

        // --- 4. Copy scripts + prefabs + all scenes (for changeScene) ---
        if let scriptsDir = ProjectManager.shared.scriptsURL {
            copyFiles(from: scriptsDir, to: sourcesScripts,
                      extensions: Set(["js"]), fm: fm)
        }
        if let prefabsDir = ProjectManager.shared.prefabsURL {
            copyFiles(from: prefabsDir, to: sourcesPrefabs,
                      extensions: Set(["json"]), fm: fm)
        }
        if let scenesDir = ProjectManager.shared.scenesURL {
            copyFiles(from: scenesDir, to: sourcesScenes,
                      extensions: Set(["json"]), fm: fm)
        }
        // Animation clips (node.playAnimation resolves these on device;
        // AnimationLibrary reads <project root>/animations.json and the
        // exported game points its project root at Resources/).
        if let animationsFile = ProjectManager.shared.currentProjectURL?
            .appendingPathComponent("animations.json"),
           fm.fileExists(atPath: animationsFile.path) {
            try? fm.copyItem(at: animationsFile,
                             to: sourcesResources.appendingPathComponent("animations.json"))
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

        if preset.platform.supportsTouchControls {
            try generateTouchControls()
                .write(to: sourcesApp.appendingPathComponent("TouchControls.swift"),
                       atomically: true, encoding: .utf8)
        }

        // Game controllers work on every platform (required on Apple TV,
        // optional MFi/DualSense/Xbox controllers on iPhone/iPad).
        try generateControllerInput()
            .write(to: sourcesApp.appendingPathComponent("ControllerInput.swift"),
                   atomically: true, encoding: .utf8)

        // --- 7. Copy engine sources (or leave instructions) ---
        let engineCopied = copyEngineSources(to: sourcesEngine, fm: fm)
        if !engineCopied {
            try generateEngineStubs()
                .write(to: sourcesEngine.appendingPathComponent("EngineStubs.swift"),
                       atomically: true, encoding: .utf8)
        }

        Log.info("Exported \(preset.gameName) for \(preset.platform.rawValue) to \(destinationURL.path)"
                 + (engineCopied ? " (engine sources included)" : " (copy engine sources manually — see EngineStubs.swift)"))
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

    // MARK: - Engine source auto-copy

    /// Engine files that must NOT ship in exported games:
    /// editor-side AI tooling and the macOS demo scene.
    private let excludedEngineFiles: Set<String> = [
        "AssetGenerator.swift",
        "AssetDownloadQueue.swift",
        "AIConfiguration.swift",
        "DemoScene.swift",
    ]

    /// Copies the cross-platform engine sources into the export.
    /// Looks for the engine source tree at:
    ///   1. UserDefaults "IngotEngineSourcePath"
    ///   2. An "EngineSource" folder inside the app bundle
    /// Returns true if any files were copied.
    private func copyEngineSources(to engineDir: URL, fm: FileManager) -> Bool {
        var candidates: [URL] = []
        if let path = UserDefaults.standard.string(forKey: "IngotEngineSourcePath") {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("EngineSource") {
            candidates.append(bundled)
        }

        let engineSubdirs = ["Core", "Logic", "Scene", "Physics", "Platform"]

        for candidate in candidates {
            // Accept either the IngotEngine/ folder itself or its parent.
            let base: URL
            if fm.fileExists(atPath: candidate.appendingPathComponent("Core/Engine.swift").path) {
                base = candidate
            } else if fm.fileExists(atPath: candidate.appendingPathComponent("IngotEngine/Core/Engine.swift").path) {
                base = candidate.appendingPathComponent("IngotEngine")
            } else {
                continue
            }

            var copiedCount = 0
            for subdir in engineSubdirs {
                let dir = base.appendingPathComponent(subdir)
                guard let files = try? fm.contentsOfDirectory(at: dir,
                                                              includingPropertiesForKeys: nil,
                                                              options: .skipsHiddenFiles) else { continue }
                for file in files
                where file.pathExtension == "swift" && !excludedEngineFiles.contains(file.lastPathComponent) {
                    let dest = engineDir.appendingPathComponent(file.lastPathComponent)
                    try? fm.removeItem(at: dest)
                    if (try? fm.copyItem(at: file, to: dest)) != nil {
                        copiedCount += 1
                    }
                }
            }

            if copiedCount > 0 {
                Log.info("Copied \(copiedCount) engine source files from \(base.path)")
                return true
            }
        }

        return false
    }

    // MARK: - Code generation

    private func generatePackageManifest(preset: ExportPreset) -> String {
        // iPhone/iPad exports use the Swift Playgrounds app-package
        // product type so Xcode runs them as a real installable app
        // (bundle ID, accent color, orientations) with zero setup.
        // Apple TV keeps a plain executable target — .iOSApplication
        // does not support tvOS.
        if preset.platform.supportsTouchControls {
            return """
            // swift-tools-version: 5.9
            import PackageDescription
            import AppleProductTypes

            let package = Package(
                name: "\(preset.gameName)",
                platforms: [\(preset.platform.swiftPlatform)],
                products: [
                    .iOSApplication(
                        name: "\(preset.gameName)",
                        targets: ["App"],
                        bundleIdentifier: "\(preset.bundleID)",
                        displayVersion: "1.0",
                        bundleVersion: "1",
                        accentColor: .presetColor(.orange),
                        supportedDeviceFamilies: [.pad, .phone],
                        supportedInterfaceOrientations: [.landscapeRight, .landscapeLeft]
                    )
                ],
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

        return """
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
        let touchSetup = preset.platform.supportsTouchControls
            ? """
                    // Virtual joystick + action button overlay.
                    let controls = TouchControls(frame: view.bounds)
                    controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    view.addSubview(controls)
            """
            : """
                    // Apple TV: hook up GCController input here.
            """

        return """
        //  GameViewController.swift — Auto-generated by Ingot Engine
        //  Target: \(preset.platform.rawValue)
        //
        //  Mirrors the editor's renderer: z-sorted, per-texture-batched
        //  instanced quads with per-instance modulate color, tile maps,
        //  and CPU particles.

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
            var color: simd_float4
        }

        struct RenderInstance {
            var modelMatrix: simd_float4x4
            var uvRect: simd_float4
            var color: simd_float4
            var texture: MTLTexture?
            var zIndex: Int
        }

        class GameViewController: UIViewController, MTKViewDelegate {

            var device: MTLDevice!
            var commandQueue: MTLCommandQueue!
            var pipelineState: MTLRenderPipelineState!
            var instanceBuffer: MTLBuffer!
            private var instanceCapacity = 256
            private var lastFrameTime: CFTimeInterval = 0
            var engine = Engine()
            private var fallbackTexture: MTLTexture!

            // Design resolution (from project.json): the game world is
            // authored against this size and scaled to fit any screen.
            let designWidth: Float = \(preset.designWidth)
            let designHeight: Float = \(preset.designHeight)

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

        \(touchSetup)

                // Physical game controllers (required input on Apple TV,
                // optional on iPhone/iPad).
                ControllerInput.shared.start()

                commandQueue = device.makeCommandQueue()!
                buildPipeline(for: metalView)
                makeInstanceBuffer(capacity: instanceCapacity)
                makeFallbackTexture()

                loadScene()
                engine.isPlaying = true
            }

            private func makeInstanceBuffer(capacity: Int) {
                let bufferSize = MemoryLayout<SpriteData>.stride * capacity
                instanceBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
                instanceCapacity = capacity
            }

            private func ensureInstanceCapacity(_ needed: Int) {
                guard needed > instanceCapacity else { return }
                var capacity = instanceCapacity
                while capacity < needed { capacity *= 2 }
                makeInstanceBuffer(capacity: capacity)
            }

            private func makeFallbackTexture() {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
                descriptor.usage = .shaderRead
                fallbackTexture = device.makeTexture(descriptor: descriptor)
                let pixel: [UInt8] = [255, 255, 255, 255]
                fallbackTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                                        mipmapLevel: 0, withBytes: pixel, bytesPerRow: 4)
            }

            private func loadScene() {
                // Point the project manager at the bundled Resources folder
                // so scripts (Scripts/) and prefabs (Prefabs/) resolve.
                if let resourceRoot = Bundle.main.url(forResource: "Resources", withExtension: nil) {
                    ProjectManager.shared.currentProjectURL = resourceRoot
                }

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

                // Runtime scene changes (the changeScene action / JS
                // call) load bundled scenes by name.
                engine.sceneLoader = { [weak self] name in
                    guard let self,
                          let url = Bundle.main.url(forResource: name, withExtension: "json",
                                                     subdirectory: "Resources/Scenes"),
                          let sceneJSON = try? String(contentsOf: url, encoding: .utf8),
                          let sceneRoot = SceneDeserializer.deserialize(jsonString: sceneJSON) else {
                        return nil
                    }
                    let next = Scene()
                    next.rootNode = sceneRoot
                    SceneDeserializer.restoreActiveCamera(scene: next, fromJSON: sceneJSON)
                    self.assignTextures(to: sceneRoot, loader: MTKTextureLoader(device: self.device))
                    return next
                }
            }

            private func loadNamedTexture(_ name: String, loader: MTKTextureLoader) -> MTLTexture? {
                for ext in ["png", "jpg", "jpeg"] {
                    if let url = Bundle.main.url(forResource: name, withExtension: ext,
                                                  subdirectory: "Resources"),
                       let tex = try? loader.newTexture(URL: url, options: [.SRGB: false as NSNumber]) {
                        return tex
                    }
                }
                return nil
            }

            /// Loads a texture by exact asset file name (e.g. "hero.png"),
            /// as recorded in the node's textureName by the editor.
            private func loadAssetTexture(_ fileName: String, loader: MTKTextureLoader) -> MTLTexture? {
                for subdirectory in ["Resources", "Resources/Assets"] {
                    if let url = Bundle.main.url(forResource: fileName, withExtension: nil,
                                                  subdirectory: subdirectory),
                       let tex = try? loader.newTexture(URL: url, options: [.SRGB: false as NSNumber]) {
                        return tex
                    }
                }
                return nil
            }

            private func assignTextures(to node: Node, loader: MTKTextureLoader) {
                if let sprite = node as? SpriteNode, sprite.texture == nil,
                   !(node is ShapeNode), !(node is TextNode) {
                    sprite.texture = sprite.textureName.flatMap { loadAssetTexture($0, loader: loader) }
                        ?? loadNamedTexture(sprite.name, loader: loader)
                        ?? loadNamedTexture("test_sprite", loader: loader)
                        ?? fallbackTexture
                }
                if let tileMap = node as? TileMapNode, tileMap.texture == nil {
                    tileMap.texture = tileMap.textureName.flatMap { loadAssetTexture($0, loader: loader) }
                        ?? loadNamedTexture(tileMap.name, loader: loader)
                        ?? loadNamedTexture("test_sprite", loader: loader)
                        ?? fallbackTexture
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

            private func collectRenderInstances(from node: Node, into result: inout [RenderInstance]) {
                guard node.isEnabled else { return }

                if let shape = node as? ShapeNode {
                    shape.ensureTexture(device: device)
                } else if let text = node as? TextNode {
                    text.ensureTexture(device: device)
                }

                if let sprite = node as? SpriteNode, sprite.texture != nil {
                    result.append(RenderInstance(
                        modelMatrix: sprite.globalTransform,
                        uvRect: sprite.uvRect,
                        color: sprite.modulate,
                        texture: sprite.texture,
                        zIndex: sprite.zIndex))
                }

                if let tileMap = node as? TileMapNode {
                    let atlas = tileMap.texture ?? fallbackTexture
                    for (coord, tileIndex) in tileMap.tiles {
                        result.append(RenderInstance(
                            modelMatrix: tileMap.modelMatrix(for: coord),
                            uvRect: tileMap.uvRect(forTileIndex: tileIndex),
                            color: simd_float4(1, 1, 1, 1),
                            texture: atlas,
                            zIndex: tileMap.zIndex))
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
                            zIndex: particles.zIndex))
                    }
                }

                for child in node.children {
                    collectRenderInstances(from: child, into: &result)
                }
            }

            func draw(in view: MTKView) {
                let now = CACurrentMediaTime()
                let rawDelta = Float(now - lastFrameTime)
                lastFrameTime = now

                let w = Float(view.drawableSize.width)
                let h = Float(view.drawableSize.height)

                engine.step(deltaTime: rawDelta)

                var instances: [RenderInstance] = []
                if let root = engine.currentScene?.rootNode {
                    collectRenderInstances(from: root, into: &instances)
                }

                let sorted = instances.enumerated()
                    .sorted { ($0.element.zIndex, $0.offset) < ($1.element.zIndex, $1.offset) }
                    .map { $0.element }

                let count = sorted.count
                ensureInstanceCapacity(count)

                let ptr = instanceBuffer.contents().bindMemory(to: SpriteData.self,
                                                               capacity: max(count, 1))
                for i in 0..<count {
                    ptr[i] = SpriteData(modelMatrix: sorted[i].modelMatrix,
                                        uvRect: sorted[i].uvRect,
                                        color: sorted[i].color)
                }

                // Build view-projection matrix with camera + shake support.
                // fitScale maps the design resolution onto the real
                // screen, so the game shows the same world area on an
                // iPhone SE, an iPad Pro, and a 4K TV.
                let fitScale = min(w / designWidth, h / designHeight)

                let projection = orthographicProjection(width: w, height: h)
                let viewMatrix: simd_float4x4
                if let camera = engine.currentScene?.activeCamera {
                    let camPos = camera.globalTransform.columns.3
                    let z = camera.zoom * fitScale
                    let cx = camPos.x + camera.shakeOffset.x
                    let cy = camPos.y + camera.shakeOffset.y
                    viewMatrix = translationMatrix(tx: w/2, ty: h/2)
                               * scaleMatrix(sx: z, sy: z)
                               * translationMatrix(tx: -cx, ty: -cy)
                } else {
                    // No camera: letterbox the design rect on screen.
                    viewMatrix = translationMatrix(tx: (w - designWidth * fitScale) / 2,
                                                   ty: (h - designHeight * fitScale) / 2)
                               * scaleMatrix(sx: fitScale, sy: fitScale)
                }
                var uniforms = Uniforms(viewProjectionMatrix: projection * viewMatrix)

                guard let rpd = view.currentRenderPassDescriptor,
                      let cb = commandQueue.makeCommandBuffer(),
                      let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

                enc.setRenderPipelineState(pipelineState)
                enc.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
                enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                enc.setVertexBuffer(instanceBuffer, offset: 0, index: 2)

                var batchStart = 0
                while batchStart < count {
                    let batchTexture = sorted[batchStart].texture ?? fallbackTexture!
                    var batchEnd = batchStart + 1
                    while batchEnd < count && sorted[batchEnd].texture === sorted[batchStart].texture {
                        batchEnd += 1
                    }
                    enc.setFragmentTexture(batchTexture, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: vertices.count,
                                       instanceCount: batchEnd - batchStart,
                                       baseInstance: batchStart)
                    batchStart = batchEnd
                }

                enc.endEncoding()
                if let drawable = view.currentDrawable { cb.present(drawable) }
                cb.commit()
            }
        }
        """
    }

    /// A UIKit overlay translating touches into InputManager actions:
    /// left half of the screen = virtual joystick (move_left/right/up/down),
    /// right half = action button. The exported game plays with the same
    /// action names the editor's keyboard uses, so behaviors and scripts
    /// run unchanged on iPhone and iPad.
    private func generateTouchControls() -> String {
        """
        //  TouchControls.swift — Auto-generated by Ingot Engine
        //
        //  Virtual joystick (left half) + action button (right half).
        //  Feeds the same InputManager action names as the editor's
        //  keyboard mapping, so gameplay logic is platform-agnostic.

        import UIKit

        class TouchControls: UIView {

            /// Distance (points) a joystick touch must move before a
            /// direction engages. Small enough to feel instant, big
            /// enough to avoid jitter.
            private let deadZone: CGFloat = 18

            private var joystickTouch: UITouch?
            private var joystickOrigin: CGPoint = .zero
            private var actionTouch: UITouch?

            private let joystickBase = CAShapeLayer()
            private let joystickThumb = CAShapeLayer()

            override init(frame: CGRect) {
                super.init(frame: frame)
                backgroundColor = .clear
                isMultipleTouchEnabled = true

                joystickBase.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
                joystickThumb.fillColor = UIColor.white.withAlphaComponent(0.28).cgColor
                joystickBase.isHidden = true
                joystickThumb.isHidden = true
                layer.addSublayer(joystickBase)
                layer.addSublayer(joystickThumb)
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

            // MARK: - Touch handling

            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
                for touch in touches {
                    let point = touch.location(in: self)
                    if point.x < bounds.midX && joystickTouch == nil {
                        joystickTouch = touch
                        joystickOrigin = point
                        showJoystick(at: point)
                    } else if actionTouch == nil {
                        actionTouch = touch
                        InputManager.shared.setActionPressed("action", isPressed: true)
                    }
                }
            }

            override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
                guard let touch = joystickTouch, touches.contains(touch) else { return }
                let point = touch.location(in: self)
                updateJoystick(to: point)

                let dx = point.x - joystickOrigin.x
                let dy = point.y - joystickOrigin.y

                // Screen Y grows downward; world Y grows upward.
                InputManager.shared.setActionPressed("move_left",  isPressed: dx < -deadZone)
                InputManager.shared.setActionPressed("move_right", isPressed: dx >  deadZone)
                InputManager.shared.setActionPressed("move_up",    isPressed: dy < -deadZone)
                InputManager.shared.setActionPressed("move_down",  isPressed: dy >  deadZone)
            }

            override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
                endTouches(touches)
            }

            override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
                endTouches(touches)
            }

            private func endTouches(_ touches: Set<UITouch>) {
                for touch in touches {
                    if touch == joystickTouch {
                        joystickTouch = nil
                        hideJoystick()
                        for action in ["move_left", "move_right", "move_up", "move_down"] {
                            InputManager.shared.setActionPressed(action, isPressed: false)
                        }
                    }
                    if touch == actionTouch {
                        actionTouch = nil
                        InputManager.shared.setActionPressed("action", isPressed: false)
                    }
                }
            }

            // MARK: - Joystick visuals

            private func showJoystick(at point: CGPoint) {
                joystickBase.path = UIBezierPath(
                    ovalIn: CGRect(x: point.x - 55, y: point.y - 55, width: 110, height: 110)).cgPath
                joystickBase.isHidden = false
                updateJoystick(to: point)
                joystickThumb.isHidden = false
            }

            private func updateJoystick(to point: CGPoint) {
                var dx = point.x - joystickOrigin.x
                var dy = point.y - joystickOrigin.y
                let length = sqrt(dx * dx + dy * dy)
                if length > 45 {  // Clamp the thumb inside the base ring.
                    dx = dx / length * 45
                    dy = dy / length * 45
                }
                let x = joystickOrigin.x + dx
                let y = joystickOrigin.y + dy
                joystickThumb.path = UIBezierPath(
                    ovalIn: CGRect(x: x - 25, y: y - 25, width: 50, height: 50)).cgPath
            }

            private func hideJoystick() {
                joystickBase.isHidden = true
                joystickThumb.isHidden = true
            }
        }
        """
    }

    /// A GameController adapter feeding the same InputManager action
    /// names as the keyboard and touch overlay. On Apple TV this is
    /// the primary input; on iPhone/iPad it lets MFi / DualSense /
    /// Xbox controllers take over from the touch overlay.
    private func generateControllerInput() -> String {
        """
        //  ControllerInput.swift — Auto-generated by Ingot Engine
        //
        //  Maps the left thumbstick + d-pad to move_left/right/up/down
        //  and button A to "action". Works on Apple TV (Siri Remote's
        //  game-controller profile and MFi controllers) and on
        //  iPhone/iPad with any supported controller.

        import Foundation
        import GameController

        final class ControllerInput {

            static let shared = ControllerInput()

            /// Stick deflection below this is treated as centered.
            private let deadZone: Float = 0.3

            private init() {}

            func start() {
                NotificationCenter.default.addObserver(
                    forName: .GCControllerDidConnect, object: nil, queue: .main
                ) { [weak self] note in
                    if let controller = note.object as? GCController {
                        self?.configure(controller)
                    }
                }
                GCController.controllers().forEach(configure)
                GCController.startWirelessControllerDiscovery()
            }

            private func configure(_ controller: GCController) {
                if let gamepad = controller.extendedGamepad {
                    gamepad.valueChangedHandler = { [weak self] pad, _ in
                        self?.readExtended(pad)
                    }
                } else if let micro = controller.microGamepad {
                    // Siri Remote / basic profile.
                    micro.reportsAbsoluteDpadValues = true
                    micro.valueChangedHandler = { [weak self] pad, _ in
                        self?.readMicro(pad)
                    }
                }
            }

            private func readExtended(_ pad: GCExtendedGamepad) {
                let x = pad.leftThumbstick.xAxis.value + pad.dpad.xAxis.value
                let y = pad.leftThumbstick.yAxis.value + pad.dpad.yAxis.value
                apply(x: x, y: y)
                InputManager.shared.setActionPressed("action", isPressed: pad.buttonA.isPressed)
            }

            private func readMicro(_ pad: GCMicroGamepad) {
                apply(x: pad.dpad.xAxis.value, y: pad.dpad.yAxis.value)
                InputManager.shared.setActionPressed("action", isPressed: pad.buttonA.isPressed)
            }

            private func apply(x: Float, y: Float) {
                InputManager.shared.setActionPressed("move_left",  isPressed: x < -deadZone)
                InputManager.shared.setActionPressed("move_right", isPressed: x >  deadZone)
                InputManager.shared.setActionPressed("move_up",    isPressed: y >  deadZone)
                InputManager.shared.setActionPressed("move_down",  isPressed: y < -deadZone)
            }
        }
        """
    }

    /// Generates a minimal stub file explaining what engine files to copy.
    /// Only written when the engine sources could not be auto-copied.
    private func generateEngineStubs() -> String {
        """
        //  EngineStubs.swift — Auto-generated by Ingot Engine
        //
        //  The exporter could not locate the Ingot Engine sources, so
        //  they were not copied automatically. Either:
        //
        //    A) Point the editor at the engine sources once:
        //         defaults write <editor bundle id> IngotEngineSourcePath \\
        //             /path/to/IngotEngine/IngotEngine
        //       then re-export, or
        //
        //    B) Copy these files into this directory by hand:
        //
        //  From Core/:
        //    Engine.swift, GameClock.swift, Math.swift, ProjectManager.swift,
        //    ProjectFile.swift, AssetHandle.swift, Log.swift, Tween.swift,
        //    FrameAnimation.swift, Node+JSExport.swift
        //
        //  From Scene/:
        //    Node.swift, SpriteNode.swift, CameraNode.swift, Scene.swift,
        //    ShapeNode.swift, TextNode.swift, AudioNode.swift, CollisionNode.swift,
        //    TimerNode.swift, ParticleNode.swift, TileMapNode.swift, Prefab.swift,
        //    SceneSerializer.swift, SceneDeserializer.swift
        //
        //  From Logic/:
        //    Behavior.swift, ScriptBehavior.swift, Signal.swift, EventBus.swift
        //
        //  From Physics/:
        //    PhysicsBody.swift, PhysicsWorld.swift
        //
        //  From Platform/:
        //    InputManager.swift, AudioManager.swift, MusicPlayer.swift
        //
        //  Do NOT copy: AppShell/ (macOS editor), AssetGenerator.swift,
        //  AssetDownloadQueue.swift, AIConfiguration.swift, DemoScene.swift.
        """
    }
}
