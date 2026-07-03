//
//  AnimationEditorViewController.swift
//  IngotEngine
//
//  §5.7 — The Animation Editor (its own window).
//
//  Character-based animation authoring (Godot SpriteFrames-style):
//  create a character ("Player", "Slime", …), then define every clip
//  it can perform — idle_up, run_left, attack — each bound to its own
//  sprite sheet from the Asset Library. Because the SHEET IS SAVED ON
//  THE CLIP, playing "run_left" swaps the sprite's texture to
//  run_left.png automatically; scripts just call
//  node.playAnimation("run_left") (or "Player/run_left" when two
//  characters share a clip name).
//
//    Left:  character popup + the selected character's clips
//    Right: clip settings (sheet, grid, frame range, fps, loop)
//           and a live preview playing from the clip's own sheet
//

import Cocoa

class AnimationEditorViewController: NSViewController,
                                     NSTableViewDataSource,
                                     NSTableViewDelegate {

    /// Called after any clip change so the editor can refresh menus.
    var onLibraryChanged: (() -> Void)?

    // --- Character + clip list ---
    private var characterPopup: NSPopUpButton!
    private var clipTable: NSTableView!
    private var visibleClips: [AnimationClip] = []

    /// nil = the "(No Character)" group.
    private var selectedCharacter: String?

    // --- Clip fields ---
    private var nameField: NSTextField!
    private var sheetPopup: NSPopUpButton!
    private var gridWidthField: NSTextField!
    private var gridHeightField: NSTextField!
    private var startFrameField: NSTextField!
    private var endFrameField: NSTextField!
    private var fpsField: NSTextField!
    private var loopsCheckbox: NSButton!
    private var statusLabel: NSTextField!

    // --- Preview ---
    private var previewImageView: NSImageView!
    private var previewTimer: Timer?
    private var previewSheet: CGImage?
    private var previewFrame = 0
    private var previewAccumulator: Double = 0

    // MARK: - Layout

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 460))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Left column: character picker + clips ---
        let characterLabel = NSTextField(labelWithString: "CHARACTER")
        characterLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        characterLabel.textColor = .tertiaryLabelColor

        characterPopup = NSPopUpButton()
        characterPopup.controlSize = .small
        characterPopup.target = self
        characterPopup.action = #selector(characterChanged)

        let newCharacterButton = NSButton(title: "New Character…", target: self,
                                          action: #selector(newCharacterClicked))
        newCharacterButton.bezelStyle = .rounded
        newCharacterButton.controlSize = .small

        clipTable = NSTableView()
        clipTable.dataSource = self
        clipTable.delegate = self
        clipTable.headerView = nil
        clipTable.rowHeight = 32
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Clip"))
        clipTable.addTableColumn(column)

        let listScroll = NSScrollView()
        listScroll.documentView = clipTable
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true

        let addClipButton = NSButton(title: "+", target: self, action: #selector(addClipClicked))
        addClipButton.bezelStyle = .smallSquare
        let removeClipButton = NSButton(title: "−", target: self, action: #selector(removeClipClicked))
        removeClipButton.bezelStyle = .smallSquare
        let listButtons = NSStackView(views: [addClipButton, removeClipButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 4

        let leftStack = NSStackView(views: [characterLabel, characterPopup, newCharacterButton,
                                            listScroll, listButtons])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 8
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Right column: clip fields + preview ---
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            return l
        }
        func field(_ placeholder: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = placeholder
            f.controlSize = .small
            f.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return f
        }

        nameField = field("run_left")
        nameField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        sheetPopup = NSPopUpButton()
        sheetPopup.controlSize = .small
        sheetPopup.target = self
        sheetPopup.action = #selector(sheetChanged)

        gridWidthField = field("8")
        gridHeightField = field("1")
        startFrameField = field("0")
        endFrameField = field("7")
        fpsField = field("8")
        loopsCheckbox = NSButton(checkboxWithTitle: "Loops", target: nil, action: nil)
        loopsCheckbox.state = .on

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Sprite Sheet"), sheetPopup],
            [label("Grid Cols"), gridWidthField],
            [label("Grid Rows"), gridHeightField],
            [label("Start Frame"), startFrameField],
            [label("End Frame"), endFrameField],
            [label("FPS"), fpsField],
            [NSGridCell.emptyContentView, loopsCheckbox],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8

        let saveButton = NSButton(title: "Save Clip", target: self, action: #selector(saveClipClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let previewHeader = NSTextField(labelWithString: "PREVIEW (from the clip's sheet)")
        previewHeader.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        previewHeader.textColor = .tertiaryLabelColor

        previewImageView = NSImageView()
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        previewImageView.layer?.cornerRadius = 6
        previewImageView.widthAnchor.constraint(equalToConstant: 170).isActive = true
        previewImageView.heightAnchor.constraint(equalToConstant: 170).isActive = true

        let rightStack = NSStackView(views: [grid, saveButton, statusLabel,
                                             previewHeader, previewImageView])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 10
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(leftStack)
        view.addSubview(rightStack)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            leftStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            leftStack.widthAnchor.constraint(equalToConstant: 200),
            listScroll.widthAnchor.constraint(equalToConstant: 200),

            rightStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            rightStack.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 24),
            rightStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        reloadCharacters()
        reloadSheets()
        reloadClips()
        startPreviewTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        previewTimer?.invalidate()
        previewTimer = nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadCharacters()
        reloadSheets()
        reloadClips()
        startPreviewTimer()
    }

    // MARK: - Characters

    private func reloadCharacters() {
        let characters = AnimationLibrary.characters()
        characterPopup.removeAllItems()
        characterPopup.addItem(withTitle: "(No Character)")
        characterPopup.addItems(withTitles: characters)

        if let selected = selectedCharacter, characters.contains(selected) {
            characterPopup.selectItem(withTitle: selected)
        } else if let first = characters.first, selectedCharacter != nil {
            selectedCharacter = first
            characterPopup.selectItem(withTitle: first)
        } else {
            characterPopup.selectItem(at: 0)
        }
    }

    @objc private func characterChanged() {
        selectedCharacter = characterPopup.indexOfSelectedItem == 0
            ? nil : characterPopup.titleOfSelectedItem
        reloadClips()
    }

    @objc private func newCharacterClicked() {
        let alert = NSAlert()
        alert.messageText = "New Character"
        alert.informativeText = "A character groups all the animations one object can perform (Player, Slime, Boss…)."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameInput = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        nameInput.placeholderString = "Player"
        alert.accessoryView = nameInput
        alert.window.initialFirstResponder = nameInput

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let character = nameInput.stringValue.trimmingCharacters(in: .whitespaces)
        guard !character.isEmpty else { return }

        // A character exists once it has a clip — start it with one.
        var clip = AnimationClip(name: "idle")
        clip.character = character
        AnimationLibrary.save(clip)

        selectedCharacter = character
        reloadCharacters()
        reloadClips()
        selectClip(named: "idle")
        onLibraryChanged?()
    }

    // MARK: - Clips

    private func reloadClips() {
        visibleClips = AnimationLibrary.clips(forCharacter: selectedCharacter)
        clipTable.reloadData()
        if let first = visibleClips.first {
            populateFields(with: first)
            clipTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func selectClip(named name: String) {
        if let row = visibleClips.firstIndex(where: { $0.name == name }) {
            clipTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            populateFields(with: visibleClips[row])
        }
    }

    private func selectedClip() -> AnimationClip? {
        let row = clipTable.selectedRow
        guard row >= 0, row < visibleClips.count else { return nil }
        return visibleClips[row]
    }

    @objc private func addClipClicked() {
        var index = 1
        var name = "clip"
        let existing = Set(visibleClips.map { $0.name })
        while existing.contains(name) {
            index += 1
            name = "clip\(index)"
        }
        var clip = AnimationClip(name: name)
        clip.character = selectedCharacter
        AnimationLibrary.save(clip)
        reloadClips()
        selectClip(named: name)
        onLibraryChanged?()
    }

    @objc private func removeClipClicked() {
        guard let clip = selectedClip() else { return }
        AnimationLibrary.delete(named: clip.qualifiedName)
        reloadClips()
        reloadCharacters()
        onLibraryChanged?()
    }

    @objc private func saveClipClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            statusLabel.stringValue = "Give the clip a name."
            return
        }

        var clip = AnimationClip(
            name: name,
            gridWidth: max(Int(gridWidthField.stringValue) ?? 2, 1),
            gridHeight: max(Int(gridHeightField.stringValue) ?? 2, 1),
            startFrame: max(Int(startFrameField.stringValue) ?? 0, 0),
            endFrame: max(Int(endFrameField.stringValue) ?? 0, 0),
            fps: max(Float(fpsField.stringValue) ?? 8, 0.1),
            loops: loopsCheckbox.state == .on
        )

        // Keep the frame range inside the sheet: 10 frames = indices
        // 0–9. An end frame past the last cell would sample outside
        // the atlas and blink at the end of every loop.
        let lastCell = clip.gridWidth * clip.gridHeight - 1
        if clip.endFrame > lastCell {
            clip.endFrame = lastCell
            endFrameField.stringValue = String(lastCell)
            statusLabel.stringValue = "End frame clamped to \(lastCell) (the sheet's last cell)."
        }
        clip.startFrame = min(clip.startFrame, clip.endFrame)

        clip.character = selectedCharacter
        clip.textureName = selectedSheetName()

        // Renaming: drop the previously selected clip's old key.
        if let old = selectedClip(), old.name != name {
            AnimationLibrary.delete(named: old.qualifiedName)
        }

        AnimationLibrary.save(clip)
        reloadClips()
        selectClip(named: name)

        let playName = clip.qualifiedName
        statusLabel.stringValue = "Saved — node.playAnimation(\"\(playName)\")"
        onLibraryChanged?()
    }

    private func populateFields(with clip: AnimationClip) {
        nameField.stringValue = clip.name
        gridWidthField.stringValue = String(clip.gridWidth)
        gridHeightField.stringValue = String(clip.gridHeight)
        startFrameField.stringValue = String(clip.startFrame)
        endFrameField.stringValue = String(clip.endFrame)
        fpsField.stringValue = String(format: "%.1f", clip.fps)
        loopsCheckbox.state = clip.loops ? .on : .off

        // The clip's own sheet drives the popup and the preview.
        if let sheet = clip.textureName, sheetPopup.itemTitles.contains(sheet) {
            sheetPopup.selectItem(withTitle: sheet)
        } else {
            sheetPopup.selectItem(at: 0)   // "(none)"
        }
        loadPreviewSheet()
        previewFrame = 0
    }

    // MARK: - Sprite sheets + preview

    private func reloadSheets() {
        sheetPopup.removeAllItems()
        sheetPopup.addItem(withTitle: "(none)")

        guard let assetsDir = ProjectManager.shared.assetsURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: assetsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return }

        let images = files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
            .sorted()
        sheetPopup.addItems(withTitles: images)
    }

    private func selectedSheetName() -> String? {
        guard sheetPopup.indexOfSelectedItem > 0 else { return nil }
        return sheetPopup.titleOfSelectedItem
    }

    @objc private func sheetChanged() {
        loadPreviewSheet()
    }

    private func loadPreviewSheet() {
        previewSheet = nil
        previewImageView.image = nil
        guard let sheet = selectedSheetName(),
              let assetsDir = ProjectManager.shared.assetsURL,
              let image = NSImage(contentsOf: assetsDir.appendingPathComponent(sheet)) else {
            return
        }
        previewSheet = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.advancePreview()
        }
    }

    /// Steps the preview at the clip's own fps (the timer ticks at
    /// 12 Hz; frames advance when enough time has accumulated).
    private func advancePreview() {
        guard let sheet = previewSheet else { return }

        let gridWidth = max(Int(gridWidthField.stringValue) ?? 2, 1)
        let gridHeight = max(Int(gridHeightField.stringValue) ?? 2, 1)
        let lastCell = gridWidth * gridHeight - 1
        let startFrame = min(max(Int(startFrameField.stringValue) ?? 0, 0), lastCell)
        let endFrame = min(max(Int(endFrameField.stringValue) ?? startFrame, startFrame), lastCell)
        let fps = max(Double(fpsField.stringValue) ?? 8, 0.1)
        let frameCount = endFrame - startFrame + 1

        previewAccumulator += 1.0 / 12.0
        if previewAccumulator >= 1.0 / fps {
            previewAccumulator = 0
            previewFrame = (previewFrame + 1) % frameCount
        }

        let index = startFrame + previewFrame
        let column = index % gridWidth
        let row = index / gridWidth

        let cellWidth = sheet.width / gridWidth
        let cellHeight = sheet.height / gridHeight
        guard cellWidth > 0, cellHeight > 0, row < gridHeight else { return }

        let cropRect = CGRect(x: column * cellWidth, y: row * cellHeight,
                              width: cellWidth, height: cellHeight)
        guard let cropped = sheet.cropping(to: cropRect) else { return }

        previewImageView.image = NSImage(cgImage: cropped,
                                         size: NSSize(width: cellWidth, height: cellHeight))
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleClips.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < visibleClips.count else { return nil }
        let clip = visibleClips[row]

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: clip.name)
        label.font = NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false

        let sheetHint = NSTextField(labelWithString: clip.textureName ?? "no sheet")
        sheetHint.font = NSFont.systemFont(ofSize: 9)
        sheetHint.textColor = clip.textureName == nil ? .systemOrange : .tertiaryLabelColor
        sheetHint.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(label)
        cell.addSubview(sheetHint)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: -1),
            sheetHint.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            sheetHint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: -2),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let clip = selectedClip() else { return }
        populateFields(with: clip)
    }
}
