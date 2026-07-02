//
//  SidebarViewController.swift
//  IngotEngine
//
//  Scene hierarchy panel with node-type icons and action bar.
//

import Cocoa

class SidebarViewController: NSViewController,
                              NSOutlineViewDataSource,
                              NSOutlineViewDelegate,
                              NSTextFieldDelegate {

    private var outlineView: NSOutlineView!

    var onNodeSelected: ((Node?) -> Void)?
    var onTreeChanged: (() -> Void)?
    /// Fired before a node is added or removed (for undo snapshots).
    var onBeforeTreeEdit: (() -> Void)?
    var onExportRequested: (() -> Void)?
    var onPlayToggle: (() -> Void)?
    var onSaveScene: (() -> Void)?
    var onLoadScene: (() -> Void)?
    private var playButton: NSButton!

    var rootNode: Node? {
        didSet {
            outlineView?.reloadData()
            outlineView?.expandItem(nil, expandChildren: true)
        }
    }

    /// Re-reads the tree (names, enabled state, new/removed nodes).
    /// Called after AI commands and inspector edits.
    func refresh() {
        outlineView?.reloadData()
        outlineView?.expandItem(nil, expandChildren: true)
    }

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        self.view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Header ---
        let header = NSTextField(labelWithString: "SCENE HIERARCHY")
        header.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        header.textColor = .tertiaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        // --- Outline view ---
        outlineView = NSOutlineView()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 16
        outlineView.rowHeight = 24
        outlineView.selectionHighlightStyle = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NodeName"))
        column.title = "Node"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // --- Bottom action bar ---
        let addButton = makeBarButton("plus", action: #selector(addButtonClicked(_:)), tooltip: "Add Node")
        let removeButton = makeBarButton("minus", action: #selector(removeButtonClicked), tooltip: "Remove Node")

        playButton = makeBarButton("play.fill", action: #selector(playButtonClicked), tooltip: "Play / Stop")

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actionBar = NSStackView(views: [addButton, removeButton, spacer, playButton])
        actionBar.orientation = .horizontal
        actionBar.spacing = 2
        actionBar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func makeBarButton(_ symbolName: String, action: Selector, tooltip: String) -> NSButton {
        let btn = NSButton(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)!,
                           target: self, action: action)
        btn.bezelStyle = .smallSquare
        btn.isBordered = false
        btn.toolTip = tooltip
        return btn
    }

    // MARK: - Actions

    @objc private func addButtonClicked(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action) in [
            ("Empty Node",     #selector(addEmptyNode)),
            ("Sprite Node",    #selector(addSpriteNode)),
            ("Shape Node",     #selector(addShapeNode)),
            ("Text Node",      #selector(addTextNode)),
            ("Camera Node",    #selector(addCameraNode)),
            ("Audio Node",     #selector(addAudioNode)),
            ("Collision Node", #selector(addCollisionNode)),
            ("Particle Node",  #selector(addParticleNode)),
            ("Tile Map Node",  #selector(addTileMapNode)),
            ("Timer Node",     #selector(addTimerNode)),
        ] as [(String, Selector)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func addEmptyNode() {
        let n = Node(); n.name = "Node"; addNodeToScene(n)
    }
    @objc private func addSpriteNode() {
        let n = SpriteNode(); n.name = "Sprite"; addNodeToScene(n)
    }
    @objc private func addShapeNode() {
        let n = ShapeNode(); n.name = "Shape"; n.color = (0.2, 0.6, 1.0, 1.0); addNodeToScene(n)
    }
    @objc private func addTextNode() {
        let n = TextNode(); n.name = "Text"; addNodeToScene(n)
    }
    @objc private func addCameraNode() {
        let n = CameraNode(); n.name = "Camera"; addNodeToScene(n)
    }
    @objc private func addAudioNode() {
        let n = AudioNode(); n.name = "Audio"; addNodeToScene(n)
    }
    @objc private func addCollisionNode() {
        let n = CollisionNode(); n.name = "Trigger"; addNodeToScene(n)
    }
    @objc private func addParticleNode() {
        let n = ParticleNode(); n.name = "Particles"; addNodeToScene(n)
    }
    @objc private func addTileMapNode() {
        let n = TileMapNode(); n.name = "TileMap"; addNodeToScene(n)
    }
    @objc private func addTimerNode() {
        let n = TimerNode(); n.name = "Timer"; addNodeToScene(n)
    }

    private func addNodeToScene(_ node: Node) {
        onBeforeTreeEdit?()
        let parent = selectedNode() ?? rootNode
        parent?.addChild(node)
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onNodeSelected?(node)
        }
        onTreeChanged?()
    }

    @objc private func removeButtonClicked() {
        guard let node = selectedNode(), node !== rootNode else { return }
        onBeforeTreeEdit?()
        PhysicsWorld.current?.removeBodies(ownedBy: node)
        node.removeFromParent()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        outlineView.deselectAll(nil)
        onNodeSelected?(nil)
        onTreeChanged?()
    }

    @objc private func playButtonClicked() { onPlayToggle?() }

    func updatePlayButton(isPlaying: Bool) {
        let sym = isPlaying ? "stop.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: isPlaying ? "Stop" : "Play")
    }

    private func selectedNode() -> Node? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? Node
    }

    // MARK: - Node type icons

    private func iconForNode(_ node: Node) -> NSImage? {
        let name: String
        switch node {
        case is CameraNode:    name = "camera"
        case is CollisionNode: name = "shield"
        case is AudioNode:     name = "speaker.wave.2"
        case is TimerNode:     name = "timer"
        case is ParticleNode:  name = "sparkles"
        case is TileMapNode:   name = "square.grid.3x3"
        case is TextNode:      name = "textformat"
        case is ShapeNode:     name = "rectangle.fill"
        case is SpriteNode:    name = "photo"
        default:               name = "cube"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootNode != nil ? 1 : 0 }
        return (item as? Node)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView,
                     child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootNode! }
        return (item as! Node).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView,
                     isItemExpandable item: Any) -> Bool {
        (item as? Node)?.children.isEmpty == false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {

        let cellID = NSUserInterfaceItemIdentifier("NodeCell")
        var cellView = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView

        if cellView == nil {
            let cell = NSTableCellView()
            cell.identifier = cellID

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.translatesAutoresizingMaskIntoConstraints = false
            // Double-click renames the node in place.
            textField.isEditable = true
            textField.delegate = self
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            cellView = cell
        }

        if let node = item as? Node {
            cellView?.textField?.stringValue = node.name
            cellView?.imageView?.image = iconForNode(node)
            cellView?.imageView?.contentTintColor = node.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
            cellView?.textField?.textColor = node.isEnabled ? .labelColor : .tertiaryLabelColor
        }

        return cellView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        if row >= 0, let node = outlineView.item(atRow: row) as? Node {
            onNodeSelected?(node)
        } else {
            onNodeSelected?(nil)
        }
    }

    // MARK: - NSTextFieldDelegate (inline rename)

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = outlineView.row(for: field)
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != node.name else {
            field.stringValue = node.name
            return
        }

        onBeforeTreeEdit?()
        node.name = newName
        // Re-select so the inspector and event sheet pick up the rename.
        onNodeSelected?(node)
    }
}

