//
//  EditorViewController.swift
//  IngotEngine
//
//  The top-level editor shell.
//
//  Layout is organized around the user's flow, left → right:
//  "what exists → what you see → what it is", with assets and the AI
//  copilot always visible (no tab-hunting for the two most-used tools):
//
//  ┌───────────────┬──────────────────────────┬─────────────────┐
//  │ SCENE         │                          │ INSPECTOR       │
//  │ HIERARCHY     │        VIEWPORT          │ (per-type)      │
//  ├───────────────┤                          ├─────────────────┤
//  │ ASSET LIBRARY │──────────────────────────│ AI COPILOT      │
//  │ import /      │ LOGIC: Event Sheet |     │ (always open,   │
//  │ assign /      │        Script Editor     │  knows the      │
//  │ prefabs       │ (for the selected node)  │  selection)     │
//  └───────────────┴──────────────────────────┴─────────────────┘
//
//  Toolbar: Save · Scenes ▾ · Play/Stop · ✦ AI Settings · Export
//

import Cocoa
import MetalKit

// MARK: - Toolbar item identifiers
private extension NSToolbarItem.Identifier {
    static let playStop   = NSToolbarItem.Identifier("PlayStop")
    static let save       = NSToolbarItem.Identifier("Save")
    static let scenes     = NSToolbarItem.Identifier("Scenes")
    static let export     = NSToolbarItem.Identifier("Export")
    static let aiSettings = NSToolbarItem.Identifier("AISettings")
}

class EditorViewController: NSSplitViewController {

    // --- The single Engine instance ---
    let engine = Engine()

    private var sidebar: SidebarViewController!
    private var assetLibrary: AssetLibraryViewController!
    private var viewport: ViewportViewController!
    private var inspector: InspectorViewController!
    private var chatPanel: ChatPanelViewController!
    private var eventSheet: EventSheetViewController!
    private var scriptEditor: ScriptEditorViewController!

    private let aiBridge = AIEngineBridge()

    /// Provider, model IDs, and keys — loaded from UserDefaults +
    /// Keychain, edited via the AI Settings toolbar sheet.
    private var aiSettings = AISettings.load()

    private var playStopButton: NSToolbarItem?

    /// The scene file currently being edited (Scenes/<name>.json).
    private var currentSceneName = ProjectManager.shared.projectFile.entryScene

    /// Loaded project textures, cached by asset file name.
    private var textureCache: [String: MTLTexture] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Outer split: three columns ---
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        // --- Left column: scene hierarchy over asset library ---
        let leftColumn = NSSplitViewController()
        leftColumn.splitView.isVertical = false
        leftColumn.splitView.dividerStyle = .thin

        sidebar = SidebarViewController()
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 180
        leftColumn.addSplitViewItem(sidebarItem)

        assetLibrary = AssetLibraryViewController()
        let assetsItem = NSSplitViewItem(viewController: assetLibrary)
        assetsItem.minimumThickness = 170
        assetsItem.canCollapse = true
        leftColumn.addSplitViewItem(assetsItem)

        let leftItem = NSSplitViewItem(viewController: leftColumn)
        leftItem.minimumThickness = 230
        leftItem.maximumThickness = 340
        leftItem.canCollapse = true
        addSplitViewItem(leftItem)

        // --- Center column: viewport over the logic panel ---
        let centerColumn = NSSplitViewController()
        centerColumn.splitView.isVertical = false
        centerColumn.splitView.dividerStyle = .thin

        viewport = ViewportViewController()
        viewport.engine = engine
        let viewportItem = NSSplitViewItem(viewController: viewport)
        viewportItem.minimumThickness = 320
        centerColumn.addSplitViewItem(viewportItem)

        let logicTabs = NSTabViewController()
        logicTabs.tabStyle = .segmentedControlOnTop

        eventSheet = EventSheetViewController()
        eventSheet.title = "Event Sheet"
        logicTabs.addChild(eventSheet)

        scriptEditor = ScriptEditorViewController()
        scriptEditor.title = "Script Editor"
        scriptEditor.aiBridge = aiBridge
        scriptEditor.sceneProvider = { [weak self] in self?.engine.currentScene }
        scriptEditor.settingsProvider = { [weak self] in self?.aiSettings ?? AISettings() }
        logicTabs.addChild(scriptEditor)

        let logicItem = NSSplitViewItem(viewController: logicTabs)
        logicItem.minimumThickness = 150
        logicItem.canCollapse = true
        centerColumn.addSplitViewItem(logicItem)

        let centerItem = NSSplitViewItem(viewController: centerColumn)
        centerItem.minimumThickness = 400
        addSplitViewItem(centerItem)

        // --- Right column: inspector over the AI copilot ---
        let rightColumn = NSSplitViewController()
        rightColumn.splitView.isVertical = false
        rightColumn.splitView.dividerStyle = .thin

        inspector = InspectorViewController()
        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 220
        rightColumn.addSplitViewItem(inspectorItem)

        chatPanel = ChatPanelViewController()
        let chatItem = NSSplitViewItem(viewController: chatPanel)
        chatItem.minimumThickness = 160
        chatItem.canCollapse = true
        rightColumn.addSplitViewItem(chatItem)

        let rightItem = NSSplitViewItem(viewController: rightColumn)
        rightItem.minimumThickness = 270
        rightItem.maximumThickness = 460
        rightItem.canCollapse = true
        addSplitViewItem(rightItem)

        wireCallbacks()
    }

    // MARK: - Panel wiring

    private func wireCallbacks() {

        sidebar.onNodeSelected = { [weak self] node in
            self?.inspector.selectedNode = node
            self?.eventSheet.targetNode = node
            self?.chatPanel.setContext(node.map { "Selected: \($0.name)" } ?? "No selection — commands target the whole scene")
        }
        sidebar.onBeforeTreeEdit = { [weak self] in
            self?.registerUndoSnapshot()
        }
        sidebar.onPlayToggle = { [weak self] in
            self?.togglePlay()
        }
        sidebar.onSaveScene = { [weak self] in
            self?.saveCurrentScene()
        }
        sidebar.onLoadScene = { [weak self] in
            self?.loadSceneFromDisk()
        }
        sidebar.onExportRequested = { [weak self] in
            self?.exportToiOS()
        }

        chatPanel.onPromptSubmitted = { [weak self] prompt in
            self?.processAIPrompt(prompt)
        }

        inspector.onBeforeEdit = { [weak self] in
            self?.registerUndoSnapshot()
        }
        inspector.onNodeEdited = { [weak self] in
            self?.sidebar.refresh()
        }
        inspector.onPaintStateChanged = { [weak self] in
            guard let self else { return }
            let state = self.inspector.paintState
            self.viewport.paintTarget = state.target
            self.viewport.paintTileIndex = state.index
        }
        inspector.onPrefabSaved = { [weak self] name in
            self?.assetLibrary.refresh()
            self?.chatPanel.appendToHistory("Saved prefab \"\(name)\" — it's in the Asset Library.")
        }

        viewport.onNodePicked = { [weak self] node in
            self?.inspector.selectedNode = node
            self?.eventSheet.targetNode = node
            self?.chatPanel.setContext(node.map { "Selected: \($0.name)" } ?? "No selection — commands target the whole scene")
        }
        viewport.onNodeDragMoved = { [weak self] in
            self?.inspector.refreshUI()
        }
        viewport.onDragWillBegin = { [weak self] in
            self?.registerUndoSnapshot()
        }
        viewport.onPaintWillBegin = { [weak self] in
            self?.registerUndoSnapshot()
        }

        eventSheet.onBeforeEdit = { [weak self] in
            self?.registerUndoSnapshot()
        }

        // --- Asset library: the import → assign flow ---
        assetLibrary.onLog = { [weak self] message in
            self?.chatPanel.appendToHistory(message)
        }
        assetLibrary.onAssignTexture = { [weak self] url in
            self?.assignTextureAsset(url)
        }
        assetLibrary.onAssignAudio = { [weak self] fileName in
            self?.assignAudioAsset(fileName)
        }
        assetLibrary.onPlacePrefab = { [weak self] name in
            self?.placePrefab(named: name)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if engine.currentScene == nil {
            let demoScene = DemoScene()
            demoScene.setup(texture: viewport.texture)
            engine.currentScene = demoScene
        }

        if let sceneRoot = engine.currentScene?.rootNode {
            sidebar.rootNode = sceneRoot
        }

        if let device = viewport.device {
            let generator = AssetGenerator(device: device)
            aiBridge.downloadQueue = AssetDownloadQueue(
                generator: generator,
                audioManager: engine.audio,
                device: device
            )
        }

        // AI-created sprites/tile maps get the editor's default texture
        // so they're visible the instant the command runs.
        aiBridge.defaultTextureProvider = { [weak self] in
            self?.viewport.texture
        }

        // Runtime scene changes (the changeScene action / JS call) load
        // scenes from the project's Scenes/ folder during Play mode.
        engine.sceneLoader = { [weak self] name in
            guard let self,
                  let result = ProjectManager.shared.loadScene(named: name) else { return nil }
            let scene = Scene()
            scene.rootNode = result.rootNode
            self.assignProjectTextures(to: result.rootNode)
            SceneDeserializer.restoreActiveCamera(scene: scene, fromJSON: result.json)
            return scene
        }
        engine.onSceneChanged = { [weak self] scene in
            guard let self else { return }
            self.sidebar.rootNode = scene.rootNode
            self.inspector.selectedNode = nil
            self.eventSheet.targetNode = nil
            self.chatPanel.appendToHistory("Scene changed.")
        }
    }

    // MARK: - Textures (project asset pipeline)

    /// Loads a texture from the project's Assets/ folder, cached.
    private func loadProjectTexture(named name: String) -> MTLTexture? {
        if let cached = textureCache[name] { return cached }

        guard let assetsDir = ProjectManager.shared.assetsURL,
              let device = viewport.device else { return nil }

        let url = assetsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let loader = MTKTextureLoader(device: device)
        guard let texture = try? loader.newTexture(URL: url, options: [.SRGB: false as NSNumber]) else {
            return nil
        }
        textureCache[name] = texture
        return texture
    }

    /// Restores textures across a loaded tree: assets referenced by
    /// textureName load from the project; everything else gets the
    /// default texture. Shape/Text nodes generate their own.
    private func assignProjectTextures(to node: Node) {
        if let sprite = node as? SpriteNode, !(node is ShapeNode), !(node is TextNode) {
            if let name = sprite.textureName, let texture = loadProjectTexture(named: name) {
                sprite.texture = texture
            } else if sprite.texture == nil {
                sprite.texture = viewport.texture
            }
        }
        if let tileMap = node as? TileMapNode {
            if let name = tileMap.textureName, let texture = loadProjectTexture(named: name) {
                tileMap.texture = texture
            } else if tileMap.texture == nil {
                tileMap.texture = viewport.texture
            }
        }
        for child in node.children {
            assignProjectTextures(to: child)
        }
    }

    // MARK: - Asset assignment (double-click in the Asset Library)

    private func assignTextureAsset(_ url: URL) {
        guard let node = inspector.selectedNode else {
            chatPanel.appendToHistory("Select a Sprite or Tile Map first, then double-click the texture.")
            return
        }

        let name = url.lastPathComponent
        guard let texture = loadProjectTexture(named: name) else {
            chatPanel.appendToHistory("Could not load \"\(name)\".")
            return
        }

        if let tileMap = node as? TileMapNode {
            registerUndoSnapshot()
            tileMap.texture = texture
            tileMap.textureName = name
            chatPanel.appendToHistory("Atlas \"\(name)\" → \"\(node.name)\".")
        } else if node is ShapeNode || node is TextNode {
            chatPanel.appendToHistory("\"\(node.name)\" draws its own texture — use a Sprite Node for images.")
        } else if let sprite = node as? SpriteNode {
            registerUndoSnapshot()
            sprite.texture = texture
            sprite.textureName = name
            chatPanel.appendToHistory("Texture \"\(name)\" → \"\(node.name)\".")
        } else {
            chatPanel.appendToHistory("\"\(node.name)\" can't take a texture — select a Sprite or Tile Map.")
        }
    }

    private func assignAudioAsset(_ fileName: String) {
        guard let audio = inspector.selectedNode as? AudioNode else {
            chatPanel.appendToHistory("Select an Audio Node first, then double-click the sound.")
            return
        }
        registerUndoSnapshot()
        audio.soundFile = fileName
        inspector.refreshUI()
        chatPanel.appendToHistory("Sound \"\(fileName)\" → \"\(audio.name)\".")
    }

    private func placePrefab(named name: String) {
        guard let scene = engine.currentScene else { return }
        guard let instance = PrefabLibrary.instantiate(named: name) else {
            chatPanel.appendToHistory("Could not load prefab \"\(name)\".")
            return
        }

        registerUndoSnapshot()
        instance.position = simd_float2(400, 300)
        assignProjectTextures(to: instance)
        scene.rootNode.addChild(instance)
        sidebar.refresh()
        chatPanel.appendToHistory("Placed prefab \"\(name)\" at (400, 300).")
    }

    // MARK: - Play / Stop

    private func togglePlay() {
        engine.isPlaying.toggle()

        // Re-register physics on every play start so nodes added since
        // the scene was set (sidebar, AI commands, painted tiles) collide.
        if engine.isPlaying, let scene = engine.currentScene {
            engine.physicsWorld.removeAllBodies()
            scene.registerPhysicsBodies(with: engine.physicsWorld)
        }

        sidebar.updatePlayButton(isPlaying: engine.isPlaying)
        updatePlayStopToolbarItem()

        chatPanel.appendToHistory(engine.isPlaying ? "▶ Playing" : "■ Stopped")
    }

    private func updatePlayStopToolbarItem() {
        guard let item = playStopButton else { return }
        let symbolName = engine.isPlaying ? "stop.fill" : "play.fill"
        let label = engine.isPlaying ? "Stop" : "Play"
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.label = label
    }

    // MARK: - Scenes (save / load / switch / create)

    private func saveCurrentScene() {
        guard let scene = engine.currentScene else {
            chatPanel.appendToHistory("Nothing to save.")
            return
        }
        ProjectManager.shared.saveScene(scene, named: currentSceneName)
        chatPanel.appendToHistory("Saved scene: \(currentSceneName)")
    }

    private func loadSceneFromDisk() {
        switchToScene(named: currentSceneName, savingCurrent: false)
    }

    /// Switches the editor to another scene file, optionally saving the
    /// one being left first (so no work is lost on switch).
    private func switchToScene(named name: String, savingCurrent: Bool = true) {
        if savingCurrent, let scene = engine.currentScene {
            ProjectManager.shared.saveScene(scene, named: currentSceneName)
        }

        guard let result = ProjectManager.shared.loadScene(named: name) else {
            chatPanel.appendToHistory("No saved scene found (\(name)).")
            return
        }

        let scene = Scene()
        scene.rootNode = result.rootNode
        assignProjectTextures(to: result.rootNode)
        SceneDeserializer.restoreActiveCamera(scene: scene, fromJSON: result.json)

        engine.currentScene = scene
        currentSceneName = name
        sidebar.rootNode = result.rootNode
        inspector.selectedNode = nil
        eventSheet.targetNode = nil
        view.window?.title = "Ingot Engine — \(ProjectManager.shared.projectFile.gameName) — \(name)"
        chatPanel.appendToHistory("Opened scene: \(name)")
    }

    private func createNewScene() {
        let alert = NSAlert()
        alert.messageText = "New Scene"
        alert.informativeText = "Name for the new scene:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        nameField.placeholderString = "Level2"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // Save what we're leaving, then build a minimal scene: a root
        // and a centered camera, ready to author.
        if let scene = engine.currentScene {
            ProjectManager.shared.saveScene(scene, named: currentSceneName)
        }

        let scene = Scene()
        let camera = CameraNode()
        camera.position = simd_float2(400, 300)
        scene.rootNode.addChild(camera)
        scene.activeCamera = camera
        ProjectManager.shared.saveScene(scene, named: name)

        engine.currentScene = scene
        currentSceneName = name
        sidebar.rootNode = scene.rootNode
        inspector.selectedNode = nil
        eventSheet.targetNode = nil
        view.window?.title = "Ingot Engine — \(ProjectManager.shared.projectFile.gameName) — \(name)"
        chatPanel.appendToHistory("Created scene: \(name)")
    }

    // MARK: - Export

    private func exportToiOS() {
        guard let scene = engine.currentScene else { return }

        let alert = NSAlert()
        alert.messageText = "Export Platform"
        alert.informativeText = "Choose the target platform."
        alert.addButton(withTitle: "iPhone / iPad")
        alert.addButton(withTitle: "Apple TV")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: view.window!) { response in
            let platform: ExportPlatform
            switch response {
            case .alertFirstButtonReturn:  platform = .iPhone
            case .alertSecondButtonReturn: platform = .appleTV
            default: return
            }

            let projectFile = ProjectManager.shared.projectFile
            let gameName = projectFile.gameName
            var preset = ExportPreset()
            preset.platform = platform
            preset.gameName = gameName
            preset.designWidth = projectFile.designWidth
            preset.designHeight = projectFile.designHeight
            let slug = gameName.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            preset.bundleID = "com.ingot.\(slug.isEmpty ? "game" : slug)"

            let panel = NSSavePanel()
            panel.title = "Export for \(platform.rawValue)"
            panel.nameFieldStringValue = "\(gameName).swiftpm"
            panel.canCreateDirectories = true

            panel.beginSheetModal(for: self.view.window!) { r in
                guard r == .OK, let url = panel.url else { return }
                let exporter = ProjectExporter()
                let assetsDir = ProjectManager.shared.assetsURL
                    ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!

                do {
                    try exporter.exportProject(scene: scene, assetsDirectory: assetsDir,
                                                to: url, preset: preset)
                    self.chatPanel.appendToHistory("Exported → \(url.lastPathComponent)")
                } catch {
                    self.chatPanel.appendToHistory("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Undo

    func registerUndoSnapshot() {
        guard let scene = engine.currentScene else { return }
        let snapshotJSON = SceneSerializer.serialize(scene)
        let textureMap = SceneDeserializer.collectTextures(from: scene.rootNode)
        let selectedName = inspector.selectedNode?.name

        undoManager?.registerUndo(withTarget: self) { target in
            target.registerUndoSnapshot()
            guard let restoredRoot = SceneDeserializer.deserialize(jsonString: snapshotJSON) else { return }
            SceneDeserializer.restoreTextures(textureMap, to: restoredRoot)
            scene.rootNode = restoredRoot
            target.engine.physicsWorld.removeAllBodies()
            scene.registerPhysicsBodies(with: target.engine.physicsWorld)
            target.sidebar.rootNode = restoredRoot
            if let name = selectedName {
                target.inspector.selectedNode = target.findNode(named: name, in: restoredRoot)
            } else {
                target.inspector.selectedNode = nil
            }
            target.inspector.refreshUI()
            target.eventSheet.targetNode = target.inspector.selectedNode
        }
        undoManager?.setActionName("Scene Edit")
    }

    private func findNode(named name: String, in node: Node) -> Node? {
        if node.name == name { return node }
        for child in node.children {
            if let found = findNode(named: name, in: child) { return found }
        }
        return nil
    }

    // MARK: - AI Copilot

    private func processAIPrompt(_ prompt: String) {
        chatPanel.appendToHistory("> \(prompt)")
        guard let scene = engine.currentScene else {
            chatPanel.appendToHistory("AI: No scene loaded.")
            return
        }
        guard aiSettings.isConfigured else {
            chatPanel.appendToHistory("AI: \(aiSettings.provider.displayName) has no API key — open AI Settings (✦ in the toolbar).")
            return
        }
        registerUndoSnapshot()
        let fullPrompt = aiBridge.buildPrompt(userText: prompt, currentScene: scene)
        chatPanel.appendToHistory("AI: Sending to \(aiSettings.activeModel)…")

        let bridge = self.aiBridge
        let settings = self.aiSettings
        chatPanel.setBusy(true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.chatPanel.setBusy(false) }
            do {
                let jsonResponse = try await bridge.sendPromptToLLM(prompt: fullPrompt, settings: settings)
                bridge.executeCommands(jsonString: jsonResponse, in: scene, settings: settings) { [weak self] log in
                    self?.chatPanel.appendToHistory("  \(log)")
                }
                // AI commands can create/delete/rename nodes and save
                // prefabs — refresh every panel that mirrors state.
                self.sidebar.refresh()
                self.assetLibrary.refresh()
                self.inspector.refreshUI()
                self.eventSheet.rebuildUI()
            } catch {
                self.chatPanel.appendToHistory("AI Error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - NSToolbarDelegate

extension EditorViewController: NSToolbarDelegate, NSMenuDelegate {

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.playStop, .flexibleSpace, .save, .scenes, .export, .aiSettings]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.save, .scenes, .flexibleSpace, .playStop, .flexibleSpace, .aiSettings, .export]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

        switch itemIdentifier {
        case .playStop:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
            item.label = "Play"
            item.toolTip = "Play / Stop the game"
            item.target = self
            item.action = #selector(toolbarPlayStop)
            playStopButton = item
            return item

        case .save:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")
            item.label = "Save"
            item.toolTip = "Save the current scene"
            item.target = self
            item.action = #selector(toolbarSave)
            return item

        case .scenes:
            // A dropdown listing every scene, plus New Scene….
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Scenes")
            item.label = "Scenes"
            item.toolTip = "Switch scene / create a new scene"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            return item

        case .export:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
            item.label = "Export"
            item.toolTip = "Export to iPhone / iPad / Apple TV"
            item.target = self
            item.action = #selector(toolbarExport)
            return item

        case .aiSettings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI Settings")
            item.label = "AI Settings"
            item.toolTip = "AI provider, models, and API keys"
            item.target = self
            item.action = #selector(toolbarAISettings)
            return item

        default:
            return nil
        }
    }

    /// Rebuilds the Scenes dropdown each time it opens, so newly saved
    /// scenes always appear.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for scene in ProjectManager.shared.listScenes() {
            let item = NSMenuItem(title: scene, action: #selector(sceneMenuChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = scene == currentSceneName ? .on : .off
            menu.addItem(item)
        }

        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No saved scenes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "New Scene…", action: #selector(newSceneChosen),
                                 keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
    }

    @objc private func sceneMenuChosen(_ sender: NSMenuItem) {
        guard sender.title != currentSceneName else { return }
        switchToScene(named: sender.title)
    }

    @objc private func newSceneChosen() {
        createNewScene()
    }

    @objc private func toolbarPlayStop() { togglePlay() }
    @objc private func toolbarSave() { saveCurrentScene() }
    @objc private func toolbarExport() { exportToiOS() }

    @objc private func toolbarAISettings() {
        let settingsSheet = AISettingsViewController()
        settingsSheet.settings = aiSettings
        settingsSheet.onSave = { [weak self] saved in
            self?.aiSettings = saved
            self?.chatPanel.appendToHistory(saved.isConfigured
                ? "AI: \(saved.provider.displayName) configured (\(saved.activeModel))."
                : "AI: \(saved.provider.displayName) selected — no API key set.")
        }
        presentAsSheet(settingsSheet)
    }
}
