//
//  AnimationEditorViewController.swift
//  IngotEngine
//
//  §5.7 — The Animation Editor (its own window).
//
//  Create and tune named sprite animations ("walk", "explode", …):
//
//    Left:  the project's clips (+ / − to add/remove)
//    Right: clip settings (sprite-sheet grid, frame range, fps, loop)
//           and a LIVE PREVIEW that plays the frames from any image
//           in the Asset Library
//
//  Saved clips live in the project's animations.json and can be played
//  from anywhere: node.playAnimation("walk") in scripts, the
//  playAnimation rule action, the AI's defineAnimation/playAnimation
//  commands, or auto-played via a sprite's Default Animation.
//

import Cocoa

class AnimationEditorViewController: NSViewController,
                                     NSTableViewDataSource,
                                     NSTableViewDelegate {

    /// Called after any clip change so the editor can refresh menus.
    var onLibraryChanged: (() -> Void)?

    // --- Clip list ---
    private var clipTable: NSTableView!
    private var clipNames: [String] = []

    // --- Clip fields ---
    private var nameField: NSTextField!
    private var gridWidthField: NSTextField!
    private var gridHeightField: NSTextField!
    private var startFrameField: NSTextField!
    private var endFrameField: NSTextField!
    private var fpsField: NSTextField!
    private var loopsCheckbox: NSButton!
    private var statusLabel: NSTextField!

    // --- Preview ---
    private var previewImageView: NSImageView!
    private var previewSourcePopup: NSPopUpButton!
    private var previewTimer: Timer?
    private var previewSheet: CGImage?
    private var previewFrame = 0

    // MARK: - Layout

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Left: clip list ---
        clipTable = NSTableView()
        clipTable.dataSource = self
        clipTable.delegate = self
        clipTable.headerView = nil
        clipTable.rowHeight = 24
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Clip"))
        clipTable.addTableColumn(column)

        let listScroll = NSScrollView()
        listScroll.documentView = clipTable
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "+", target: self, action: #selector(addClipClicked))
        addButton.bezelStyle = .smallSquare
        let removeButton = NSButton(title: "−", target: self, action: #selector(removeClipClicked))
        removeButton.bezelStyle = .smallSquare
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 4
        listButtons.translatesAutoresizingMaskIntoConstraints = false

        // --- Right: clip fields ---
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

        nameField = field("walk"); nameField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        gridWidthField = field("4")
        gridHeightField = field("4")
        startFrameField = field("0")
        endFrameField = field("3")
        fpsField = field("8")
        loopsCheckbox = NSButton(checkboxWithTitle: "Loops", target: nil, action: nil)
        loopsCheckbox.state = .on

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Grid Cols"), gridWidthField],
            [label("Grid Rows"), gridHeightField],
            [label("Start Frame"), startFrameField],
            [label("End Frame"), endFrameField],
            [label("FPS"), fpsField],
            [NSGridCell.emptyContentView, loopsCheckbox],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save Clip", target: self, action: #selector(saveClipClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor

        // --- Preview ---
        let previewHeader = NSTextField(labelWithString: "PREVIEW")
        previewHeader.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        previewHeader.textColor = .tertiaryLabelColor

        previewSourcePopup = NSPopUpButton()
        previewSourcePopup.controlSize = .small
        previewSourcePopup.target = self
        previewSourcePopup.action = #selector(previewSourceChanged)

        previewImageView = NSImageView()
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        previewImageView.layer?.cornerRadius = 6
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.widthAnchor.constraint(equalToConstant: 160).isActive = true
        previewImageView.heightAnchor.constraint(equalToConstant: 160).isActive = true

        let rightStack = NSStackView(views: [grid, saveButton, statusLabel,
                                             previewHeader, previewSourcePopup, previewImageView])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 10
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(listScroll)
        view.addSubview(listButtons)
        view.addSubview(rightStack)

        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            listScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            listScroll.widthAnchor.constraint(equalToConstant: 180),
            listScroll.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -6),

            listButtons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            listButtons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            rightStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            rightStack.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 20),
            rightStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        reloadClips()
        reloadPreviewSources()
        startPreviewTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        previewTimer?.invalidate()
        previewTimer = nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadClips()
        reloadPreviewSources()
        startPreviewTimer()
    }

    // MARK: - Clip list

    private func reloadClips() {
        clipNames = AnimationLibrary.list()
        clipTable.reloadData()
    }

    private func selectedClipName() -> String? {
        let row = clipTable.selectedRow
        guard row >= 0, row < clipNames.count else { return nil }
        return clipNames[row]
    }

    @objc private func addClipClicked() {
        var index = 1
        var name = "NewAnimation"
        while AnimationLibrary.clip(named: name) != nil {
            index += 1
            name = "NewAnimation\(index)"
        }
        AnimationLibrary.save(AnimationClip(name: name))
        reloadClips()
        if let row = clipNames.firstIndex(of: name) {
            clipTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        onLibraryChanged?()
    }

    @objc private func removeClipClicked() {
        guard let name = selectedClipName() else { return }
        AnimationLibrary.delete(named: name)
        reloadClips()
        onLibraryChanged?()
    }

    @objc private func saveClipClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            statusLabel.stringValue = "Give the clip a name."
            return
        }

        // Renaming: remove the clip that was selected under its old name.
        if let old = selectedClipName(), old != name {
            AnimationLibrary.delete(named: old)
        }

        let clip = AnimationClip(
            name: name,
            gridWidth: max(Int(gridWidthField.stringValue) ?? 2, 1),
            gridHeight: max(Int(gridHeightField.stringValue) ?? 2, 1),
            startFrame: max(Int(startFrameField.stringValue) ?? 0, 0),
            endFrame: max(Int(endFrameField.stringValue) ?? 0, 0),
            fps: max(Float(fpsField.stringValue) ?? 8, 0.1),
            loops: loopsCheckbox.state == .on
        )
        AnimationLibrary.save(clip)
        reloadClips()
        if let row = clipNames.firstIndex(of: name) {
            clipTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        statusLabel.stringValue = "Saved \"\(name)\" — play it with node.playAnimation(\"\(name)\")"
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
        previewFrame = 0
    }

    // MARK: - Preview

    private func reloadPreviewSources() {
        previewSourcePopup.removeAllItems()

        guard let assetsDir = ProjectManager.shared.assetsURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: assetsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else {
            previewSourcePopup.addItem(withTitle: "No images in Assets")
            return
        }

        let images = files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
            .sorted()

        if images.isEmpty {
            previewSourcePopup.addItem(withTitle: "No images in Assets")
        } else {
            previewSourcePopup.addItems(withTitles: images)
        }
        previewSourceChanged()
    }

    @objc private func previewSourceChanged() {
        previewSheet = nil
        guard let name = previewSourcePopup.titleOfSelectedItem,
              name != "No images in Assets",
              let assetsDir = ProjectManager.shared.assetsURL,
              let image = NSImage(contentsOf: assetsDir.appendingPathComponent(name)) else {
            previewImageView.image = nil
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

    /// Steps the preview one frame at the clip's own pacing (the timer
    /// runs at 12 Hz; frames advance when enough time has accumulated).
    private var previewAccumulator: Double = 0
    private func advancePreview() {
        guard let sheet = previewSheet else { return }

        let gridWidth = max(Int(gridWidthField.stringValue) ?? 2, 1)
        let gridHeight = max(Int(gridHeightField.stringValue) ?? 2, 1)
        let startFrame = max(Int(startFrameField.stringValue) ?? 0, 0)
        let endFrame = max(Int(endFrameField.stringValue) ?? startFrame, startFrame)
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
        clipNames.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < clipNames.count else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: clipNames[row])
        label.font = NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let name = selectedClipName(),
              let clip = AnimationLibrary.clip(named: name) else { return }
        populateFields(with: clip)
    }
}
