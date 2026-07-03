//
//  ProjectSettingsViewController.swift
//  IngotEngine
//
//  §5.8 — Project Settings sheet (Godot's Project → Project Settings).
//
//  Edits the project.json manifest in-app: game name, design
//  resolution, and which scene the EXPORTED game boots into (the
//  entry scene — distinct from lastOpenedScene, which is just the
//  editor's session restore).
//

import Cocoa

class ProjectSettingsViewController: NSViewController {

    /// Called after Save so the editor can refresh the window title.
    var onSaved: (() -> Void)?

    private var nameField: NSTextField!
    private var widthField: NSTextField!
    private var heightField: NSTextField!
    private var entryScenePopup: NSPopUpButton!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let projectFile = ProjectManager.shared.projectFile

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            return l
        }

        nameField = NSTextField(string: projectFile.gameName)
        nameField.controlSize = .small
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        widthField = NSTextField(string: String(projectFile.designWidth))
        widthField.controlSize = .small
        widthField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        heightField = NSTextField(string: String(projectFile.designHeight))
        heightField.controlSize = .small
        heightField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        entryScenePopup = NSPopUpButton()
        entryScenePopup.controlSize = .small
        let scenes = ProjectManager.shared.listScenes()
        entryScenePopup.addItems(withTitles: scenes.isEmpty ? [projectFile.entryScene] : scenes)
        entryScenePopup.selectItem(withTitle: projectFile.entryScene)

        let grid = NSGridView(views: [
            [label("Game Name"), nameField],
            [label("Design Width"), widthField],
            [label("Design Height"), heightField],
            [label("Entry Scene"), entryScenePopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "The entry scene is what exported games boot into. Design resolution is the size the game world is authored against — exports scale it to fit each device.")
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(grid)
        view.addSubview(note)
        view.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
    }

    @objc private func cancelClicked() {
        dismiss(self)
    }

    @objc private func saveClicked() {
        var projectFile = ProjectManager.shared.projectFile

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { projectFile.gameName = name }
        projectFile.designWidth = max(Int(widthField.stringValue) ?? projectFile.designWidth, 100)
        projectFile.designHeight = max(Int(heightField.stringValue) ?? projectFile.designHeight, 100)
        if let entry = entryScenePopup.titleOfSelectedItem {
            projectFile.entryScene = entry
        }

        ProjectManager.shared.projectFile = projectFile
        ProjectManager.shared.saveProjectFile()
        onSaved?()
        dismiss(self)
    }
}
