//
//  EditorViewController.swift
//  IngotEngine
//
//  The top-level editor shell with unified toolbar, undo, AI copilot,
//  and per-platform export.
//

import Cocoa

// MARK: - Toolbar item identifiers
private extension NSToolbarItem.Identifier {
    static let playStop   = NSToolbarItem.Identifier("PlayStop")
    static let save       = NSToolbarItem.Identifier("Save")
    static let load       = NSToolbarItem.Identifier("Load")
    static let export     = NSToolbarItem.Identifier("Export")
    static let aiSettings = NSToolbarItem.Identifier("AISettings")
}

class EditorViewController: NSSplitViewController {

    // --- The single Engine instance ---
    let engine = Engine()

    private var sidebar: SidebarViewController!
    private var viewport: ViewportViewController!
    private var inspector: InspectorViewController!
    private var chatPanel: ChatPanelViewController!
    private var assetBrowser: AssetBrowserViewController!
    private var eventSheet: EventSheetViewController!
    private var scriptEditor: ScriptEditorViewController!

    private let aiBridge = AIEngineBridge()

    /// Provider, model IDs, and keys — loaded from UserDefaults +
    /// Keychain, edited via the AI Settings toolbar sheet.
    private var aiSettings = AISettings.load()

    private var playStopButton: NSToolbarItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Outer split: top (workspace) / bottom (tabs) ---
        splitView.isVertical = false
        splitView.dividerStyle = .thin

        // --- Top pane: workspace ---
        let workspace = NSSplitViewController()
        workspace.splitView.isVertical = true
        workspace.splitView.dividerStyle = .thin

        sidebar = SidebarViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 350
        sidebarItem.canCollapse = true
        workspace.addSplitViewItem(sidebarItem)

        viewport = ViewportViewController()
        viewport.engine = engine
        let viewportItem = NSSplitViewItem(viewController: viewport)
        viewportItem.minimumThickness = 400
        workspace.addSplitViewItem(viewportItem)

        inspector = InspectorViewController()
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 400
        inspectorItem.canCollapse = true
        workspace.addSplitViewItem(inspectorItem)

        let workspaceItem = NSSplitViewItem(viewController: workspace)
        addSplitViewItem(workspaceItem)

        // --- Bottom pane: tabbed panel ---
        let tabController = NSTabViewController()
        tabController.tabStyle = .segmentedControlOnTop

        chatPanel = ChatPanelViewController()
        chatPanel.title = "AI Copilot"
        tabController.addChild(chatPanel)

        eventSheet = EventSheetViewController()
        eventSheet.title = "Event Sheet"
        tabController.addChild(eventSheet)

        scriptEditor = ScriptEditorViewController()
        scriptEditor.title = "Script Editor"
        scriptEditor.aiBridge = aiBridge
        scriptEditor.sceneProvider = { [weak self] in self?.engine.currentScene }
        scriptEditor.settingsProvider = { [weak self] in self?.aiSettings ?? AISettings() }
        tabController.addChild(scriptEditor)

        assetBrowser = AssetBrowserViewController()
        assetBrowser.title = "Project Files"
        tabController.addChild(assetBrowser)

        let tabItem = NSSplitViewItem(viewController: tabController)
        tabItem.minimumThickness = 140
        tabItem.canCollapse = true
        addSplitViewItem(tabItem)

        // --- Wire all callbacks ---
        sidebar.onNodeSelected = { [weak self] node in
            self?.inspector.selectedNode = node
            self?.eventSheet.targetNode = node
        }

        chatPanel.onPromptSubmitted = { [weak self] prompt in
            self?.processAIPrompt(prompt)
        }

        inspector.onBeforeEdit = { [weak self] in
            self?.registerUndoSnapshot()
        }
        inspector.onNodeEdited = { [weak self] in
            // Name/enabled changes show in the hierarchy immediately.
            self?.sidebar.refresh()
        }
        inspector.onPaintStateChanged = { [weak self] in
            guard let self else { return }
            let state = self.inspector.paintState
            self.viewport.paintTarget = state.target
            self.viewport.paintTileIndex = state.index
        }

        sidebar.onBeforeTreeEdit = { [weak self] in
            self?.registerUndoSnapshot()
        }

        viewport.onPaintWillBegin = { [weak self] in
            self?.registerUndoSnapshot()
        }

        sidebar.onExportRequested = { [weak self] in
            self?.exportToiOS()
        }

        viewport.onNodePicked = { [weak self] node in
            self?.inspector.selectedNode = node
            self?.eventSheet.targetNode = node
        }
        viewport.onNodeDragMoved = { [weak self] in
            self?.inspector.refreshUI()
        }
        viewport.onDragWillBegin = { [weak self] in
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

        eventSheet.onBeforeEdit = { [weak self] in
            self?.registerUndoSnapshot()
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
            if let tex = self.viewport.texture {
                self.assignDefaultTexture(tex, to: result.rootNode)
            }
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

    // MARK: - Save / Load

    private func saveCurrentScene() {
        guard let scene = engine.currentScene else {
            chatPanel.appendToHistory("Nothing to save.")
            return
        }
        let name = ProjectManager.shared.projectFile.entryScene
        ProjectManager.shared.saveScene(scene, named: name)
        chatPanel.appendToHistory("Saved scene: \(name)")
    }

    private func loadSceneFromDisk() {
        let name = ProjectManager.shared.projectFile.entryScene
        guard let result = ProjectManager.shared.loadScene(named: name) else {
            chatPanel.appendToHistory("No saved scene found (\(name)).")
            return
        }
        let scene = Scene()
        scene.rootNode = result.rootNode
        if let tex = viewport.texture {
            assignDefaultTexture(tex, to: result.rootNode)
        }
        SceneDeserializer.restoreActiveCamera(scene: scene, fromJSON: result.json)
        engine.currentScene = scene
        sidebar.rootNode = result.rootNode
        inspector.selectedNode = nil
        chatPanel.appendToHistory("Loaded scene: \(name)")
    }

    private func assignDefaultTexture(_ texture: MTLTexture, to node: Node) {
        // Shape/Text nodes generate their own textures lazily.
        if let sprite = node as? SpriteNode, sprite.texture == nil,
           !(node is ShapeNode), !(node is TextNode) {
            sprite.texture = texture
        }
        if let tileMap = node as? TileMapNode, tileMap.texture == nil {
            tileMap.texture = texture
        }
        for child in node.children {
            assignDefaultTexture(texture, to: child)
        }
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
                // AI commands can create/delete/rename nodes — refresh
                // every panel that mirrors the tree.
                self.sidebar.refresh()
                self.inspector.refreshUI()
                self.eventSheet.rebuildUI()
            } catch {
                self.chatPanel.appendToHistory("AI Error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - NSToolbarDelegate

extension EditorViewController: NSToolbarDelegate {

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.playStop, .flexibleSpace, .save, .load, .export, .aiSettings]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.save, .load, .flexibleSpace, .playStop, .flexibleSpace, .aiSettings, .export]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case .playStop:
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
            item.label = "Play"
            item.toolTip = "Play / Stop the game"
            item.target = self
            item.action = #selector(toolbarPlayStop)
            playStopButton = item

        case .save:
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")
            item.label = "Save"
            item.toolTip = "Save the current scene"
            item.target = self
            item.action = #selector(toolbarSave)

        case .load:
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Load")
            item.label = "Load"
            item.toolTip = "Load scene from disk"
            item.target = self
            item.action = #selector(toolbarLoad)

        case .export:
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
            item.label = "Export"
            item.toolTip = "Export to iPhone / iPad / Apple TV"
            item.target = self
            item.action = #selector(toolbarExport)

        case .aiSettings:
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI Settings")
            item.label = "AI Settings"
            item.toolTip = "AI provider, models, and API keys"
            item.target = self
            item.action = #selector(toolbarAISettings)

        default:
            return nil
        }

        return item
    }

    @objc private func toolbarPlayStop() { togglePlay() }
    @objc private func toolbarSave() { saveCurrentScene() }
    @objc private func toolbarLoad() { loadSceneFromDisk() }
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
