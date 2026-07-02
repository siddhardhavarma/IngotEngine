//
//  RuleEditorViewController.swift
//  IngotEngine
//
//  §5.4 Behavior Editor — Inline editing of one event-action rule.
//
//  Presented as a sheet from the Event Sheet. The user picks an event
//  type from a dropdown (with a parameter field where relevant) and
//  builds a list of actions, each with its own type dropdown and
//  parameter fields. Saving hands a fully-built Rule back to the
//  Event Sheet, which replaces or appends it on the node's behavior.
//

import Cocoa

class RuleEditorViewController: NSViewController {

    /// The rule to edit. nil = creating a new rule.
    var rule: Rule?

    /// Called with the built rule when the user clicks Save.
    var onSave: ((Rule) -> Void)?

    // MARK: - Event / action catalogs

    private let eventTypes = [
        "Action Held", "Action Just Pressed", "Every Frame",
        "On Start", "On Collision", "On Signal",
    ]

    // Parameter placeholder for each event type ("" = no parameter).
    private let eventParamPlaceholders = [
        "move_left / action …", "move_left / action …", "",
        "", "", "signal name",
    ]

    private let actionTypes = [
        "Move", "Rotate", "Emit Signal", "Play Sound", "Set Property",
        "Set Velocity", "Spawn Prefab", "Change Scene", "Destroy",
    ]

    // Up to three parameter placeholders per action type ("" = unused).
    private let actionParamPlaceholders: [[String]] = [
        ["X px/s", "Y px/s", ""],           // Move
        ["degrees/s", "", ""],              // Rotate
        ["signal name", "", ""],            // Emit Signal
        ["file name", "", ""],              // Play Sound
        ["property", "value", ""],          // Set Property
        ["X px/s", "Y px/s", ""],           // Set Velocity
        ["prefab", "X", "Y"],               // Spawn Prefab
        ["scene name", "", ""],             // Change Scene
        ["", "", ""],                       // Destroy
    ]

    // MARK: - UI state

    private var eventPopup: NSPopUpButton!
    private var eventParamField: NSTextField!

    /// One editable row per action.
    private final class ActionRow {
        let container = NSStackView()
        let popup = NSPopUpButton()
        let params = [NSTextField(), NSTextField(), NSTextField()]
        let removeButton = NSButton()
    }

    private var actionRows: [ActionRow] = []
    private var actionsStack: NSStackView!

    // MARK: - Layout

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- WHEN row ---
        let whenLabel = NSTextField(labelWithString: "When:")
        whenLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        whenLabel.textColor = .systemBlue

        eventPopup = NSPopUpButton()
        eventPopup.addItems(withTitles: eventTypes)
        eventPopup.target = self
        eventPopup.action = #selector(eventTypeChanged)

        eventParamField = NSTextField()
        eventParamField.controlSize = .small
        eventParamField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let whenRow = NSStackView(views: [whenLabel, eventPopup, eventParamField])
        whenRow.orientation = .horizontal
        whenRow.spacing = 8

        // --- DO rows ---
        let doLabel = NSTextField(labelWithString: "Do:")
        doLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        doLabel.textColor = .systemGreen

        actionsStack = NSStackView()
        actionsStack.orientation = .vertical
        actionsStack.alignment = .leading
        actionsStack.spacing = 6

        let actionsScroll = NSScrollView()
        actionsScroll.documentView = actionsStack
        actionsScroll.hasVerticalScroller = true
        actionsScroll.autohidesScrollers = true
        actionsScroll.drawsBackground = false

        let addActionButton = NSButton(title: "+ Add Action", target: self,
                                       action: #selector(addActionClicked))
        addActionButton.bezelStyle = .rounded
        addActionButton.controlSize = .small

        // --- Bottom buttons ---
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save Rule", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // --- Assemble ---
        let outerStack = NSStackView(views: [whenRow, doLabel, actionsScroll, addActionButton, buttonRow])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 10
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outerStack)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            outerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            outerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            outerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            actionsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            actionsScroll.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
        ])

        populateFromRule()
    }

    // MARK: - Populate from an existing rule

    private func populateFromRule() {
        guard let rule = rule else {
            // New rule: sensible default.
            eventPopup.selectItem(at: 2)  // Every Frame
            eventTypeChanged()
            addActionRow(typeIndex: 0, params: ["0", "0", ""])
            return
        }

        switch rule.event {
        case .onActionHeld(let a):
            eventPopup.selectItem(at: 0); eventParamField.stringValue = a
        case .onActionJustPressed(let a):
            eventPopup.selectItem(at: 1); eventParamField.stringValue = a
        case .everyFrame:
            eventPopup.selectItem(at: 2)
        case .onStart:
            eventPopup.selectItem(at: 3)
        case .onCollision:
            eventPopup.selectItem(at: 4)
        case .onSignal(let s):
            eventPopup.selectItem(at: 5); eventParamField.stringValue = s
        }
        eventTypeChanged()

        for action in rule.actions {
            switch action {
            case .move(let x, let y):
                addActionRow(typeIndex: 0, params: ["\(x)", "\(y)", ""])
            case .rotate(let d):
                addActionRow(typeIndex: 1, params: ["\(d)", "", ""])
            case .emitSignal(let s):
                addActionRow(typeIndex: 2, params: [s, "", ""])
            case .playSound(let f):
                addActionRow(typeIndex: 3, params: [f, "", ""])
            case .setProperty(let p, let v):
                addActionRow(typeIndex: 4, params: [p, "\(v)", ""])
            case .setVelocity(let x, let y):
                addActionRow(typeIndex: 5, params: ["\(x)", "\(y)", ""])
            case .spawnPrefab(let n, let x, let y):
                addActionRow(typeIndex: 6, params: [n, "\(x)", "\(y)"])
            case .changeScene(let s):
                addActionRow(typeIndex: 7, params: [s, "", ""])
            case .destroy:
                addActionRow(typeIndex: 8, params: ["", "", ""])
            }
        }
    }

    // MARK: - Row management

    private func addActionRow(typeIndex: Int, params: [String]) {
        let row = ActionRow()

        row.popup.addItems(withTitles: actionTypes)
        row.popup.selectItem(at: typeIndex)
        row.popup.controlSize = .small
        row.popup.target = self
        row.popup.action = #selector(actionTypeChanged(_:))

        for (i, field) in row.params.enumerated() {
            field.controlSize = .small
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            field.stringValue = i < params.count ? params[i] : ""
        }

        row.removeButton.title = "×"
        row.removeButton.bezelStyle = .smallSquare
        row.removeButton.isBordered = false
        row.removeButton.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        row.removeButton.target = self
        row.removeButton.action = #selector(removeActionClicked(_:))

        row.container.orientation = .horizontal
        row.container.spacing = 6
        row.container.addArrangedSubview(row.popup)
        row.params.forEach { row.container.addArrangedSubview($0) }
        row.container.addArrangedSubview(row.removeButton)

        actionRows.append(row)
        actionsStack.addArrangedSubview(row.container)
        applyPlaceholders(to: row)
    }

    /// Shows/hides parameter fields to match the selected action type.
    private func applyPlaceholders(to row: ActionRow) {
        let placeholders = actionParamPlaceholders[row.popup.indexOfSelectedItem]
        for (i, field) in row.params.enumerated() {
            field.placeholderString = placeholders[i]
            field.isHidden = placeholders[i].isEmpty
        }
    }

    // MARK: - Control actions

    @objc private func eventTypeChanged() {
        let placeholder = eventParamPlaceholders[eventPopup.indexOfSelectedItem]
        eventParamField.placeholderString = placeholder
        eventParamField.isHidden = placeholder.isEmpty
    }

    @objc private func actionTypeChanged(_ sender: NSPopUpButton) {
        guard let row = actionRows.first(where: { $0.popup === sender }) else { return }
        applyPlaceholders(to: row)
    }

    @objc private func addActionClicked() {
        addActionRow(typeIndex: 0, params: ["0", "0", ""])
    }

    @objc private func removeActionClicked(_ sender: NSButton) {
        guard let index = actionRows.firstIndex(where: { $0.removeButton === sender }) else { return }
        let row = actionRows.remove(at: index)
        actionsStack.removeArrangedSubview(row.container)
        row.container.removeFromSuperview()
    }

    @objc private func cancelClicked() {
        dismiss(self)
    }

    @objc private func saveClicked() {
        let actions = actionRows.compactMap { buildAction(from: $0) }
        guard !actions.isEmpty else {
            NSSound.beep()
            return
        }
        let built = Rule(event: buildEvent(), actions: actions)
        onSave?(built)
        dismiss(self)
    }

    // MARK: - Rule building

    private func buildEvent() -> GameEvent {
        let param = eventParamField.stringValue.trimmingCharacters(in: .whitespaces)
        switch eventPopup.indexOfSelectedItem {
        case 0: return .onActionHeld(param.isEmpty ? "action" : param)
        case 1: return .onActionJustPressed(param.isEmpty ? "action" : param)
        case 2: return .everyFrame
        case 3: return .onStart
        case 4: return .onCollision
        default: return .onSignal(param.isEmpty ? "Signal" : param)
        }
    }

    private func buildAction(from row: ActionRow) -> GameAction? {
        let text = row.params.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
        let num = text.map { Float($0) ?? 0 }

        switch row.popup.indexOfSelectedItem {
        case 0: return .move(x: num[0], y: num[1])
        case 1: return .rotate(degreesPerSecond: num[0])
        case 2: return text[0].isEmpty ? nil : .emitSignal(text[0])
        case 3: return text[0].isEmpty ? nil : .playSound(text[0])
        case 4: return text[0].isEmpty ? nil : .setProperty(text[0], num[1])
        case 5: return .setVelocity(x: num[0], y: num[1])
        case 6: return text[0].isEmpty ? nil : .spawnPrefab(text[0], x: num[1], y: num[2])
        case 7: return text[0].isEmpty ? nil : .changeScene(text[0])
        default: return .destroy
        }
    }
}
