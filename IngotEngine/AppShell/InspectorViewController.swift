//
//  InspectorViewController.swift
//  IngotEngine
//
//  Property inspector with grouped sections: Identity, Transform, Script.
//  Uses a flipped NSView containing a vertical NSStackView for proper
//  top-to-bottom layout inside the scroll view.
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

    // All field references for updating.
    private var nameField: NSTextField!
    private var enabledCheckbox: NSButton!
    private var posXField: NSTextField!
    private var posYField: NSTextField!
    private var rotationField: NSTextField!
    private var scaleXField: NSTextField!
    private var scaleYField: NSTextField!
    private var zIndexField: NSTextField!
    private var scriptNameField: NSTextField!

    var onBeforeEdit: (() -> Void)?

    var selectedNode: Node? {
        didSet { updateUI() }
    }

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        self.view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let margin: CGFloat = 12

        // --- "No Selection" label ---
        noSelectionLabel = NSTextField(labelWithString: "No Selection")
        noSelectionLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        noSelectionLabel.textColor = .tertiaryLabelColor
        noSelectionLabel.alignment = .center
        noSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noSelectionLabel)

        // --- Scrollable content ---
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

        // Build the form content.
        var y: CGFloat = 8

        y = addSectionHeader("IDENTITY", at: y, margin: margin)
        (nameField, y) = addField(label: "Name", placeholder: "Node", at: y, margin: margin)
        enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(enabledToggled))
        enabledCheckbox.frame = NSRect(x: margin, y: y, width: 200, height: 18)
        contentView.addSubview(enabledCheckbox)
        y += 26

        y = addSectionHeader("TRANSFORM", at: y, margin: margin)
        (posXField, y) = addField(label: "Position X", placeholder: "0", at: y, margin: margin)
        (posYField, y) = addField(label: "Position Y", placeholder: "0", at: y, margin: margin)
        (rotationField, y) = addField(label: "Rotation °", placeholder: "0", at: y, margin: margin)
        (scaleXField, y) = addField(label: "Scale X", placeholder: "1", at: y, margin: margin)
        (scaleYField, y) = addField(label: "Scale Y", placeholder: "1", at: y, margin: margin)
        (zIndexField, y) = addField(label: "Z-Index", placeholder: "0", at: y, margin: margin)

        y = addSectionHeader("SCRIPT", at: y, margin: margin)
        (scriptNameField, y) = addField(label: "File", placeholder: "MyScript.js", at: y, margin: margin)
        scriptNameField.delegate = nil // Don't treat as numeric.

        let assignBtn = NSButton(title: "Assign", target: self, action: #selector(assignScriptClicked))
        assignBtn.bezelStyle = .rounded
        assignBtn.controlSize = .small
        assignBtn.frame = NSRect(x: margin, y: y, width: 70, height: 22)
        contentView.addSubview(assignBtn)

        let createBtn = NSButton(title: "Create", target: self, action: #selector(createScriptClicked))
        createBtn.bezelStyle = .rounded
        createBtn.controlSize = .small
        createBtn.frame = NSRect(x: margin + 78, y: y, width: 70, height: 22)
        contentView.addSubview(createBtn)
        y += 32

        // Set the content view's frame height so the scroll view knows
        // how much content there is.
        contentView.frame = NSRect(x: 0, y: 0, width: 240, height: y)

        updateUI()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Keep the content view's width matching the scroll view.
        contentView.frame.size.width = scrollView.contentSize.width
    }

    // MARK: - Form builders (frame-based for reliable layout)

    private func addSectionHeader(_ title: String, at y: CGFloat, margin: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: margin, y: y + 4, width: 200, height: 14)
        contentView.addSubview(label)

        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: margin, y: y + 20, width: 220, height: 1)
        sep.autoresizingMask = [.width]
        contentView.addSubview(sep)

        return y + 28
    }

    private func addField(label labelText: String, placeholder: String,
                           at y: CGFloat, margin: CGFloat) -> (NSTextField, CGFloat) {
        let label = NSTextField(labelWithString: labelText)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: margin, y: y, width: 76, height: 16)
        label.alignment = .right
        contentView.addSubview(label)

        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.controlSize = .small
        field.frame = NSRect(x: margin + 82, y: y - 2, width: 130, height: 20)
        field.autoresizingMask = [.width]
        contentView.addSubview(field)

        return (field, y + 24)
    }

    // MARK: - UI update

    func refreshUI() { updateUI() }

    private func updateUI() {
        guard isViewLoaded else { return }

        if let node = selectedNode {
            scrollView.isHidden = false
            noSelectionLabel.isHidden = true

            nameField.stringValue = node.name
            enabledCheckbox.state = node.isEnabled ? .on : .off
            posXField.stringValue = String(format: "%.1f", node.position.x)
            posYField.stringValue = String(format: "%.1f", node.position.y)
            rotationField.stringValue = String(format: "%.1f", node.rotation * 180 / .pi)
            scaleXField.stringValue = String(format: "%.2f", node.scale.x)
            scaleYField.stringValue = String(format: "%.2f", node.scale.y)
            zIndexField.stringValue = String(node.zIndex)

            if let script = node.behaviors.first(where: { $0 is ScriptBehavior }) as? ScriptBehavior {
                scriptNameField.stringValue = script.scriptName
            } else {
                scriptNameField.stringValue = ""
            }
        } else {
            scrollView.isHidden = true
            noSelectionLabel.isHidden = false
        }
    }

    // MARK: - Actions

    @objc private func enabledToggled() {
        guard let node = selectedNode else { return }
        onBeforeEdit?()
        node.isEnabled = (enabledCheckbox.state == .on)
    }

    @objc private func assignScriptClicked() {
        guard let node = selectedNode else { return }
        let name = scriptNameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onBeforeEdit?()
        node.removeBehaviors { $0 is ScriptBehavior }
        node.addBehavior(ScriptBehavior(scriptName: name))
    }

    @objc private func createScriptClicked() {
        guard let node = selectedNode else { return }
        var name = scriptNameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            name = "\(node.name)Controller.js"
            scriptNameField.stringValue = name
        }
        onBeforeEdit?()
        ProjectManager.shared.createScriptFile(named: name)
        node.removeBehaviors { $0 is ScriptBehavior }
        node.addBehavior(ScriptBehavior(scriptName: name))
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let node = selectedNode else { return }

        if field === nameField {
            onBeforeEdit?()
            node.name = field.stringValue
            return
        }

        guard field === posXField || field === posYField ||
              field === rotationField || field === scaleXField ||
              field === scaleYField || field === zIndexField else { return }

        let value = Float(field.stringValue) ?? 0
        onBeforeEdit?()

        if field === posXField          { node.position.x = value }
        else if field === posYField     { node.position.y = value }
        else if field === rotationField { node.rotation = value * .pi / 180 }
        else if field === scaleXField   { node.scale.x = value }
        else if field === scaleYField   { node.scale.y = value }
        else if field === zIndexField   { node.zIndex = Int(value) }

        updateUI()
    }
}
