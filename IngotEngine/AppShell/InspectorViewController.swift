//
//  InspectorViewController.swift
//  IngotEngine
//
//  Property inspector with dynamic, per-node-type sections.
//
//  The form is REBUILT for each selection: only sections relevant to
//  the selected node's type are created, so the panel is always
//  gap-free — no hidden placeholder rows, no dead space. Every node
//  type is fully editable by hand (the same properties the AI copilot
//  can set):
//
//    All nodes    → Identity, Transform, Physics, Script
//    CameraNode   → zoom, follow target, smoothing
//    ShapeNode    → fill color (color well), width, height
//    TextNode     → text, font size, color
//    SpriteNode   → modulate tint
//    AudioNode    → sound file, play on start, loops, volume
//    CollisionNode→ trigger signal, size
//    TimerNode    → wait time, one shot, autostart, signal
//    ParticleNode → emission, motion, scale and color over lifetime
//    TileMapNode  → tile size, atlas grid, solid tiles, paint controls
//
//  Layout stays frame-based inside a FlippedView (top-to-bottom), with
//  a running yCursor. Controls bind through small closure handlers
//  keyed by the control's identity, so adding a row is one line.
//

import Cocoa
import simd

/// A flipped view so subviews lay out from the top, not the bottom.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class InspectorViewController: NSViewController, NSTextFieldDelegate {

    private var scrollView: NSScrollView!
    private var contentView: FlippedView!
    private var noSelectionLabel: NSTextField!

    /// Called before any edit so the editor can save an undo snapshot.
    var onBeforeEdit: (() -> Void)?

    /// Fired after edits that other panels display (name, enabled state),
    /// so the sidebar can refresh its labels.
    var onNodeEdited: (() -> Void)?

    /// Fired whenever the tile paint state may have changed (checkbox,
    /// paint index, or selection). The editor reads `paintState`.
    var onPaintStateChanged: (() -> Void)?

    /// Fired after "Save as Prefab" succeeds, with the prefab name.
    var onPrefabSaved: ((String) -> Void)?

    /// Fired when the user wants to edit the node's script — the
    /// editor opens it in the Script Editor tab.
    var onEditScript: ((String) -> Void)?

    var selectedNode: Node? {
        didSet { rebuildForm() }
    }

    /// The viewport paint target: non-nil only while Paint Mode is on
    /// and the selected node is a tile map.
    var paintState: (target: TileMapNode?, index: Int) {
        guard let checkbox = paintModeCheckbox, checkbox.state == .on,
              let tileMap = selectedNode as? TileMapNode else { return (nil, 0) }
        return (tileMap, Int(paintIndexField?.stringValue ?? "0") ?? 0)
    }

    // MARK: - Dynamic form state

    private let margin: CGFloat = 12
    private var yCursor: CGFloat = 8

    /// Commit handlers keyed by control identity.
    private var textHandlers: [ObjectIdentifier: (String) -> Void] = [:]
    private var toggleHandlers: [ObjectIdentifier: (Bool) -> Void] = [:]
    private var colorHandlers: [ObjectIdentifier: (NSColor) -> Void] = [:]
    private var buttonHandlers: [ObjectIdentifier: () -> Void] = [:]
    private var popupHandlers: [ObjectIdentifier: (String) -> Void] = [:]

    /// Closures that re-read model values into controls (refreshUI).
    private var valueRefreshers: [() -> Void] = []

    /// Views whose width must track the panel (text fields, separators).
    /// Sized explicitly — autoresizing masks accumulate bogus deltas
    /// when the form is rebuilt while the container is mid-layout.
    private var resizableViews: [NSView] = []

    /// The width the form lays out against.
    private var formWidth: CGFloat {
        max(scrollView.contentSize.width, 240)
    }

    /// Tile-paint controls (weak — they only exist for TileMapNodes).
    private weak var paintModeCheckbox: NSButton?
    private weak var paintIndexField: NSTextField?
    private weak var scriptNameField: NSTextField?

    // MARK: - View lifecycle

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        self.view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Color wells edit RGBA (particles fade out via alpha).
        NSColorPanel.shared.showsAlpha = true

        noSelectionLabel = NSTextField(labelWithString: "No Selection")
        noSelectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        noSelectionLabel.textColor = .tertiaryLabelColor
        noSelectionLabel.alignment = .center
        noSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noSelectionLabel)

        contentView = FlippedView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.documentView = contentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            noSelectionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noSelectionLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        rebuildForm()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        contentView.frame.size.width = formWidth
        applyFormWidth()
    }

    /// Explicitly resizes width-tracking views to the current panel
    /// width (labels and buttons keep their fixed frames).
    private func applyFormWidth() {
        let width = formWidth
        for view in resizableViews {
            view.frame.size.width = max(width - view.frame.origin.x - margin, 60)
        }
    }

    // MARK: - Form rebuilding

    private func clearForm() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        textHandlers.removeAll()
        toggleHandlers.removeAll()
        colorHandlers.removeAll()
        buttonHandlers.removeAll()
        popupHandlers.removeAll()
        valueRefreshers.removeAll()
        resizableViews.removeAll()
        yCursor = 8
    }

    private func rebuildForm() {
        guard isViewLoaded else { return }
        clearForm()

        guard let node = selectedNode else {
            scrollView.isHidden = true
            noSelectionLabel.isHidden = false
            onPaintStateChanged?()
            return
        }

        scrollView.isHidden = false
        noSelectionLabel.isHidden = true

        buildSections(for: node)

        contentView.frame = NSRect(x: 0, y: 0, width: formWidth, height: yCursor)
        applyFormWidth()
        onPaintStateChanged?()
    }

    /// Re-reads model values into the visible controls without
    /// rebuilding (called while dragging in the viewport, after AI
    /// commands, and after undo). Fields being edited are skipped so
    /// typing is never interrupted.
    func refreshUI() {
        guard isViewLoaded else { return }
        valueRefreshers.forEach { $0() }
    }

    // MARK: - Sections

    private func buildSections(for node: Node) {

        section("IDENTITY")
        textRow("Name", get: { node.name }) { [weak self] value in
            node.name = value
            self?.onNodeEdited?()
        }
        boolRow("Enabled", get: { node.isEnabled }) { [weak self] value in
            node.isEnabled = value
            self?.onNodeEdited?()
        }
        buttonRow("Save as Prefab") { [weak self] in
            self?.promptSavePrefab(for: node)
        }

        section("TRANSFORM")
        floatRow("Position X", get: { node.position.x }, set: { node.position.x = $0 })
        floatRow("Position Y", get: { node.position.y }, set: { node.position.y = $0 })
        floatRow("Rotation °",
                 get: { node.rotation * 180 / .pi },
                 set: { node.rotation = $0 * .pi / 180 })
        floatRow("Scale X", format: "%.2f", get: { node.scale.x }, set: { node.scale.x = $0 })
        floatRow("Scale Y", format: "%.2f", get: { node.scale.y }, set: { node.scale.y = $0 })
        intRow("Z-Index", get: { node.zIndex }, set: { node.zIndex = $0 })

        if let camera = node as? CameraNode {
            section("CAMERA")
            floatRow("Zoom", format: "%.2f", get: { camera.zoom }, set: { camera.zoom = $0 })
            textRow("Follow", placeholder: "node name (empty = off)",
                    get: { camera.followTargetName ?? "" }) { value in
                camera.followTargetName = value.isEmpty ? nil : value
            }
            floatRow("Smoothing", get: { camera.followSmoothing },
                     set: { camera.followSmoothing = $0 })
        }

        if let shape = node as? ShapeNode {
            section("SHAPE")
            colorRow("Fill",
                     get: { NSColor(srgbRed: CGFloat(shape.color.r), green: CGFloat(shape.color.g),
                                    blue: CGFloat(shape.color.b), alpha: CGFloat(shape.color.a)) },
                     set: { c in shape.color = (Float(c.redComponent), Float(c.greenComponent),
                                                Float(c.blueComponent), Float(c.alphaComponent)) })
            floatRow("Width", format: "%.0f", get: { shape.shapeWidth }, set: { shape.shapeWidth = $0 })
            floatRow("Height", format: "%.0f", get: { shape.shapeHeight }, set: { shape.shapeHeight = $0 })
        } else if let text = node as? TextNode {
            section("TEXT")
            textRow("Text", get: { text.text }) { text.text = $0 }
            floatRow("Font Size", format: "%.0f",
                     get: { Float(text.fontSize) }, set: { text.fontSize = CGFloat($0) })
            colorRow("Color",
                     get: { NSColor(srgbRed: CGFloat(text.textColor.x), green: CGFloat(text.textColor.y),
                                    blue: CGFloat(text.textColor.z), alpha: CGFloat(text.textColor.w)) },
                     set: { c in text.textColor = simd_float4(Float(c.redComponent), Float(c.greenComponent),
                                                              Float(c.blueComponent), Float(c.alphaComponent)) })
        } else if let sprite = node as? SpriteNode {
            section("SPRITE")
            colorRow("Tint",
                     get: { NSColor(srgbRed: CGFloat(sprite.modulate.x), green: CGFloat(sprite.modulate.y),
                                    blue: CGFloat(sprite.modulate.z), alpha: CGFloat(sprite.modulate.w)) },
                     set: { c in sprite.modulate = simd_float4(Float(c.redComponent), Float(c.greenComponent),
                                                               Float(c.blueComponent), Float(c.alphaComponent)) })
            popupRow("Character",
                     options: ["(none)"] + AnimationLibrary.characters(),
                     get: { sprite.characterName ?? "(none)" },
                     set: { sprite.characterName = $0 == "(none)" ? nil : $0 })
            textRow("Animation", placeholder: "clip name (auto-plays)",
                    get: { sprite.defaultAnimationName ?? "" }) { value in
                sprite.defaultAnimationName = value.isEmpty ? nil : value
            }
        }

        if let audio = node as? AudioNode {
            section("AUDIO")
            textRow("File", placeholder: "sound.wav", get: { audio.soundFile }) { audio.soundFile = $0 }
            boolRow("Play On Start", get: { audio.playOnStart }) { audio.playOnStart = $0 }
            boolRow("Loops", get: { audio.loops }) { audio.loops = $0 }
            floatRow("Volume", format: "%.2f", get: { audio.volume }, set: { audio.volume = $0 })
        }

        if let trigger = node as? CollisionNode {
            section("TRIGGER")
            textRow("Signal", get: { trigger.triggerSignal }) { trigger.triggerSignal = $0 }
            floatRow("Width", format: "%.0f",
                     get: { trigger.triggerSize.x }, set: { trigger.triggerSize.x = $0 })
            floatRow("Height", format: "%.0f",
                     get: { trigger.triggerSize.y }, set: { trigger.triggerSize.y = $0 })
        }

        if let timer = node as? TimerNode {
            section("TIMER")
            floatRow("Wait (s)", format: "%.2f", get: { timer.waitTime }, set: { timer.waitTime = $0 })
            boolRow("One Shot", get: { timer.oneShot }) { timer.oneShot = $0 }
            boolRow("Autostart", get: { timer.autostart }) { timer.autostart = $0 }
            textRow("Signal", get: { timer.timeoutSignal }) { timer.timeoutSignal = $0 }
        }

        if let particles = node as? ParticleNode {
            section("PARTICLES")
            intRow("Amount", get: { particles.amount }, set: { particles.amount = max($0, 0) })
            floatRow("Lifetime", format: "%.2f",
                     get: { particles.lifetime }, set: { particles.lifetime = max($0, 0.01) })
            boolRow("One Shot", get: { particles.oneShot }) { particles.oneShot = $0 }
            floatRow("Direction °", get: { particles.direction }, set: { particles.direction = $0 })
            floatRow("Spread °", get: { particles.spread }, set: { particles.spread = $0 })
            floatRow("Speed", get: { particles.initialVelocity }, set: { particles.initialVelocity = $0 })
            floatRow("Gravity X", get: { particles.gravity.x }, set: { particles.gravity.x = $0 })
            floatRow("Gravity Y", get: { particles.gravity.y }, set: { particles.gravity.y = $0 })
            floatRow("Start Size", get: { particles.startScale }, set: { particles.startScale = $0 })
            floatRow("End Size", get: { particles.endScale }, set: { particles.endScale = $0 })
            colorRow("Start Color",
                     get: { NSColor(srgbRed: CGFloat(particles.startColor.x), green: CGFloat(particles.startColor.y),
                                    blue: CGFloat(particles.startColor.z), alpha: CGFloat(particles.startColor.w)) },
                     set: { c in particles.startColor = simd_float4(Float(c.redComponent), Float(c.greenComponent),
                                                                    Float(c.blueComponent), Float(c.alphaComponent)) })
            colorRow("End Color",
                     get: { NSColor(srgbRed: CGFloat(particles.endColor.x), green: CGFloat(particles.endColor.y),
                                    blue: CGFloat(particles.endColor.z), alpha: CGFloat(particles.endColor.w)) },
                     set: { c in particles.endColor = simd_float4(Float(c.redComponent), Float(c.greenComponent),
                                                                  Float(c.blueComponent), Float(c.alphaComponent)) })
        }

        if let tileMap = node as? TileMapNode {
            section("TILE MAP")
            floatRow("Tile W", format: "%.0f",
                     get: { tileMap.tileWidth },
                     set: { tileMap.tileWidth = max($0, 1); tileMap.rebuildCollision() })
            floatRow("Tile H", format: "%.0f",
                     get: { tileMap.tileHeight },
                     set: { tileMap.tileHeight = max($0, 1); tileMap.rebuildCollision() })
            intRow("Atlas Cols", get: { tileMap.atlasColumns }, set: { tileMap.atlasColumns = $0 })
            intRow("Atlas Rows", get: { tileMap.atlasRows }, set: { tileMap.atlasRows = $0 })
            textRow("Solid Tiles", placeholder: "0, 1, 5",
                    get: { tileMap.solidTiles.sorted().map(String.init).joined(separator: ", ") }) { value in
                tileMap.solidTiles = Set(value.split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            }

            // Paint controls (not undoable edits themselves — strokes are).
            let indexField = addField(label: "Paint Tile", initial: "0", placeholder: "0")
            paintIndexField = indexField
            textHandlers[ObjectIdentifier(indexField)] = { [weak self] _ in
                self?.onPaintStateChanged?()
            }

            let checkbox = addCheckbox(title: "Paint Mode (right-click erases)")
            // Painting is the primary interaction with a tile map (they
            // aren't drag-movable in the viewport), so paint mode is ON
            // whenever a tile map is selected. Untick to disable.
            checkbox.state = .on
            paintModeCheckbox = checkbox
            toggleHandlers[ObjectIdentifier(checkbox)] = { [weak self] _ in
                self?.onPaintStateChanged?()
            }
        }

        section("PHYSICS")
        if let body = node.physicsBody {
            floatRow("Size X", format: "%.0f", get: { body.size.x }, set: { body.size.x = $0 })
            floatRow("Size Y", format: "%.0f", get: { body.size.y }, set: { body.size.y = $0 })
            boolRow("Dynamic (moves)", get: { body.isDynamic }) { body.isDynamic = $0 }
            boolRow("Trigger (no blocking)", get: { body.isTrigger }) { body.isTrigger = $0 }
            floatRow("Gravity Scale", format: "%.2f",
                     get: { body.gravityScale }, set: { body.gravityScale = $0 })
            buttonRow("Remove Body") { [weak self] in
                self?.onBeforeEdit?()
                PhysicsWorld.current?.removeBody(body)
                node.physicsBody = nil
                self?.rebuildForm()
            }
        } else {
            buttonRow("Add Physics Body") { [weak self] in
                self?.onBeforeEdit?()
                node.addPhysicsBody(PhysicsBody(size: simd_float2(100, 100), isDynamic: true))
                self?.rebuildForm()
            }
        }

        section("SCRIPT")
        let scriptField = addField(
            label: "File",
            initial: (node.behaviors.first(where: { $0 is ScriptBehavior }) as? ScriptBehavior)?.scriptName ?? "",
            placeholder: "MyScript.js"
        )
        scriptNameField = scriptField
        buttonRow("Assign", secondTitle: "Create",
                  action: { [weak self] in self?.assignScript(create: false) },
                  secondAction: { [weak self] in self?.assignScript(create: true) })
        buttonRow("Edit Script") { [weak self] in
            guard let self, let field = self.scriptNameField else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self.onEditScript?(name.hasSuffix(".js") ? name : name + ".js")
        }
    }

    // MARK: - Row builders (frame-based, top-to-bottom)

    private func section(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: margin, y: yCursor + 4, width: 200, height: 14)
        contentView.addSubview(label)

        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = NSRect(x: margin, y: yCursor + 20, width: 220, height: 1)
        contentView.addSubview(separator)
        resizableViews.append(separator)

        yCursor += 28
    }

    /// Creates a "label: [field]" row and returns the field.
    private func addField(label labelText: String, initial: String,
                          placeholder: String) -> NSTextField {
        let label = NSTextField(labelWithString: labelText)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: margin, y: yCursor, width: 76, height: 16)
        label.alignment = .right
        contentView.addSubview(label)

        let field = NSTextField()
        field.stringValue = initial
        field.placeholderString = placeholder
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.controlSize = .small
        field.frame = NSRect(x: margin + 82, y: yCursor - 2, width: 130, height: 20)
        contentView.addSubview(field)
        resizableViews.append(field)

        yCursor += 24
        return field
    }

    private func addCheckbox(title: String) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self,
                                action: #selector(checkboxToggled(_:)))
        checkbox.controlSize = .small
        checkbox.frame = NSRect(x: margin, y: yCursor, width: 220, height: 18)
        contentView.addSubview(checkbox)
        yCursor += 24
        return checkbox
    }

    private func textRow(_ label: String, placeholder: String = "",
                         get: @escaping () -> String,
                         set: @escaping (String) -> Void) {
        let field = addField(label: label, initial: get(), placeholder: placeholder)
        textHandlers[ObjectIdentifier(field)] = { [weak self] value in
            self?.onBeforeEdit?()
            set(value)
        }
        valueRefreshers.append { [weak field] in
            guard let field, field.currentEditor() == nil else { return }
            field.stringValue = get()
        }
    }

    private func floatRow(_ label: String, format: String = "%.1f",
                          get: @escaping () -> Float,
                          set: @escaping (Float) -> Void) {
        textRow(label,
                get: { String(format: format, get()) },
                set: { set(Float($0) ?? 0) })
    }

    private func intRow(_ label: String,
                        get: @escaping () -> Int,
                        set: @escaping (Int) -> Void) {
        textRow(label,
                get: { String(get()) },
                set: { set(Int($0) ?? 0) })
    }

    private func boolRow(_ title: String,
                         get: @escaping () -> Bool,
                         set: @escaping (Bool) -> Void) {
        let checkbox = addCheckbox(title: title)
        checkbox.state = get() ? .on : .off
        toggleHandlers[ObjectIdentifier(checkbox)] = { [weak self] value in
            self?.onBeforeEdit?()
            set(value)
        }
        valueRefreshers.append { [weak checkbox] in
            checkbox?.state = get() ? .on : .off
        }
    }

    /// A "label: [dropdown]" row (used for the animation character).
    private func popupRow(_ label: String, options: [String],
                          get: @escaping () -> String,
                          set: @escaping (String) -> Void) {
        let rowLabel = NSTextField(labelWithString: label)
        rowLabel.font = NSFont.systemFont(ofSize: 11)
        rowLabel.textColor = .secondaryLabelColor
        rowLabel.frame = NSRect(x: margin, y: yCursor + 2, width: 76, height: 16)
        rowLabel.alignment = .right
        contentView.addSubview(rowLabel)

        let popup = NSPopUpButton()
        popup.controlSize = .small
        popup.addItems(withTitles: options)
        popup.selectItem(withTitle: get())
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.frame = NSRect(x: margin + 82, y: yCursor - 2, width: 130, height: 20)
        contentView.addSubview(popup)
        resizableViews.append(popup)

        popupHandlers[ObjectIdentifier(popup)] = { [weak self] value in
            self?.onBeforeEdit?()
            set(value)
        }
        valueRefreshers.append { [weak popup] in
            popup?.selectItem(withTitle: get())
        }

        yCursor += 26
    }

    private func colorRow(_ label: String,
                          get: @escaping () -> NSColor,
                          set: @escaping (NSColor) -> Void) {
        let rowLabel = NSTextField(labelWithString: label)
        rowLabel.font = NSFont.systemFont(ofSize: 11)
        rowLabel.textColor = .secondaryLabelColor
        rowLabel.frame = NSRect(x: margin, y: yCursor + 2, width: 76, height: 16)
        rowLabel.alignment = .right
        contentView.addSubview(rowLabel)

        let well = NSColorWell()
        well.color = get()
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.frame = NSRect(x: margin + 82, y: yCursor - 2, width: 44, height: 22)
        contentView.addSubview(well)

        colorHandlers[ObjectIdentifier(well)] = { [weak self] color in
            self?.onBeforeEdit?()
            set(color)
        }
        valueRefreshers.append { [weak well] in
            well?.color = get()
        }

        yCursor += 28
    }

    /// One (or two, side by side) small action buttons.
    private func buttonRow(_ title: String, secondTitle: String? = nil,
                           action: @escaping () -> Void,
                           secondAction: (() -> Void)? = nil) {
        let button = NSButton(title: title, target: self, action: #selector(buttonClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.frame = NSRect(x: margin, y: yCursor, width: 100, height: 22)
        contentView.addSubview(button)
        buttonHandlers[ObjectIdentifier(button)] = action

        if let secondTitle, let secondAction {
            let second = NSButton(title: secondTitle, target: self, action: #selector(buttonClicked(_:)))
            second.bezelStyle = .rounded
            second.controlSize = .small
            second.frame = NSRect(x: margin + 108, y: yCursor, width: 100, height: 22)
            contentView.addSubview(second)
            buttonHandlers[ObjectIdentifier(second)] = secondAction
        }

        yCursor += 30
    }

    // MARK: - Control actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        toggleHandlers[ObjectIdentifier(sender)]?(sender.state == .on)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        popupHandlers[ObjectIdentifier(sender)]?(sender.titleOfSelectedItem ?? "")
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let color = sender.color.usingColorSpace(.sRGB) ?? sender.color
        colorHandlers[ObjectIdentifier(sender)]?(color)
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        buttonHandlers[ObjectIdentifier(sender)]?()
    }

    /// Asks for a prefab name and saves the node's subtree.
    private func promptSavePrefab(for node: Node) {
        let alert = NSAlert()
        alert.messageText = "Save as Prefab"
        alert.informativeText = "\"\(node.name)\" and its children become a reusable prefab."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        nameField.stringValue = node.name
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        if PrefabLibrary.save(node, named: name) {
            onPrefabSaved?(name)
        }
    }

    private func assignScript(create: Bool) {
        guard let node = selectedNode, let field = scriptNameField else { return }
        var name = field.stringValue.trimmingCharacters(in: .whitespaces)

        if create && name.isEmpty {
            name = "\(node.name)Controller.js"
            field.stringValue = name
        }
        guard !name.isEmpty else { return }

        onBeforeEdit?()
        if create {
            ProjectManager.shared.createScriptFile(named: name)
        }
        node.removeBehaviors { $0 is ScriptBehavior }
        node.addBehavior(ScriptBehavior(scriptName: name))
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let handler = textHandlers[ObjectIdentifier(field)] else { return }
        handler(field.stringValue)
        refreshUI()
    }
}
