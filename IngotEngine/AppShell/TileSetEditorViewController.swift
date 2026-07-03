//
//  TileSetEditorViewController.swift
//  IngotEngine
//
//  §5.8 — The Tile Set editor (its own window, like Animations).
//
//  A tile set bundles everything a tile map needs: the atlas image,
//  its grid, the world size of one tile, and which tiles are solid.
//  The atlas preview is visual — click cells to toggle SOLID instead
//  of typing indices. Saved sets live in tilesets.json and apply to
//  any TileMapNode from the Inspector's Tile Set popup, the Asset
//  Library (double-click), or the AI (configureTileMap + "tileSet").
//
//    Left:  saved tile sets (+/−)
//    Right: atlas + grid + tile size fields, and the clickable
//           atlas preview marking solid tiles
//

import Cocoa

// ---------------------------------------------------------------------------
// TileAtlasView — a clickable atlas grid, shared by this editor (mark
// solid tiles) and the Inspector's paint palette (pick the paint tile)
// ---------------------------------------------------------------------------

class TileAtlasView: NSView {

    /// The atlas image, drawn stretched to the view's bounds.
    var image: NSImage? { didSet { needsDisplay = true } }
    var columns = 4 { didSet { columns = max(columns, 1); needsDisplay = true } }
    var rows = 4 { didSet { rows = max(rows, 1); needsDisplay = true } }

    /// Cells drawn with the red "solid" overlay.
    var solidTiles: Set<Int> = [] { didSet { needsDisplay = true } }

    /// true → clicking toggles solidTiles (tile set editor);
    /// false → clicking picks one index (inspector paint palette).
    var marksSolidTiles = false

    var onSolidTilesChanged: ((Set<Int>) -> Void)?
    var onTilePicked: ((Int) -> Void)?

    /// Palette mode: the currently picked index (-1 = none).
    var selectedIndex = -1 { didSet { needsDisplay = true } }

    /// Flipped so cell (0, 0) — atlas index 0 — is the TOP-left,
    /// matching TileMapNode.uvRect's index math.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()

        guard let image else { return }
        image.draw(in: bounds, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.none.rawValue])

        let cellW = bounds.width / CGFloat(columns)
        let cellH = bounds.height / CGFloat(rows)

        // Grid lines.
        NSColor(white: 1, alpha: 0.18).setStroke()
        for column in 0...columns {
            let x = CGFloat(column) * cellW
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 0))
            line.line(to: NSPoint(x: x, y: bounds.height))
            line.stroke()
        }
        for row in 0...rows {
            let y = CGFloat(row) * cellH
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 0, y: y))
            line.line(to: NSPoint(x: bounds.width, y: y))
            line.stroke()
        }

        // Solid markers.
        for index in solidTiles where index >= 0 && index < columns * rows {
            let rect = cellRect(index: index, cellW: cellW, cellH: cellH)
            NSColor.systemRed.withAlphaComponent(0.28).setFill()
            rect.fill(using: .sourceOver)
            NSColor.systemRed.withAlphaComponent(0.85).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 1.5
            border.stroke()
        }

        // Palette selection.
        if !marksSolidTiles, selectedIndex >= 0, selectedIndex < columns * rows {
            let rect = cellRect(index: selectedIndex, cellW: cellW, cellH: cellH)
            NSColor.systemYellow.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 2.5
            border.stroke()
        }
    }

    private func cellRect(index: Int, cellW: CGFloat, cellH: CGFloat) -> NSRect {
        NSRect(x: CGFloat(index % columns) * cellW,
               y: CGFloat(index / columns) * cellH,
               width: cellW, height: cellH)
    }

    override func mouseDown(with event: NSEvent) {
        guard image != nil, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(point.x / (bounds.width / CGFloat(columns)))
        let row = Int(point.y / (bounds.height / CGFloat(rows)))
        guard column >= 0, column < columns, row >= 0, row < rows else { return }
        let index = row * columns + column

        if marksSolidTiles {
            if solidTiles.contains(index) {
                solidTiles.remove(index)
            } else {
                solidTiles.insert(index)
            }
            onSolidTilesChanged?(solidTiles)
        } else {
            selectedIndex = index
            onTilePicked?(index)
        }
    }
}

// ---------------------------------------------------------------------------
// The Tile Sets window
// ---------------------------------------------------------------------------

class TileSetEditorViewController: NSViewController,
                                   NSTableViewDataSource,
                                   NSTableViewDelegate,
                                   NSTextFieldDelegate {

    /// Called after any tile set change so the editor can refresh
    /// the Asset Library and Inspector.
    var onLibraryChanged: (() -> Void)?

    // --- Tile set list ---
    private var setTable: NSTableView!
    private var visibleSets: [TileSetDefinition] = []

    // --- Fields ---
    private var nameField: NSTextField!
    private var atlasPopup: NSPopUpButton!
    private var tileWidthField: NSTextField!
    private var tileHeightField: NSTextField!
    private var columnsField: NSTextField!
    private var rowsField: NSTextField!
    private var statusLabel: NSTextField!

    // --- Atlas preview ---
    private var atlasView: TileAtlasView!
    private var atlasHeightConstraint: NSLayoutConstraint!
    private let atlasWidth: CGFloat = 300

    // MARK: - Layout

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Left column: tile set list ---
        let listLabel = NSTextField(labelWithString: "TILE SETS")
        listLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        listLabel.textColor = .tertiaryLabelColor

        setTable = NSTableView()
        setTable.dataSource = self
        setTable.delegate = self
        setTable.headerView = nil
        setTable.rowHeight = 32
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TileSet"))
        setTable.addTableColumn(column)

        let listScroll = NSScrollView()
        listScroll.documentView = setTable
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true

        let addButton = NSButton(title: "+", target: self, action: #selector(addSetClicked))
        addButton.bezelStyle = .smallSquare
        let removeButton = NSButton(title: "−", target: self, action: #selector(removeSetClicked))
        removeButton.bezelStyle = .smallSquare
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 4

        let leftStack = NSStackView(views: [listLabel, listScroll, listButtons])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 8
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Right column: fields + clickable atlas ---
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
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return f
        }

        nameField = field("Terrain")
        nameField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        atlasPopup = NSPopUpButton()
        atlasPopup.controlSize = .small
        atlasPopup.target = self
        atlasPopup.action = #selector(atlasChanged)

        tileWidthField = field("32")
        tileHeightField = field("32")
        columnsField = field("16")
        rowsField = field("16")

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Atlas Image"), atlasPopup],
            [label("Tile W (px)"), tileWidthField],
            [label("Tile H (px)"), tileHeightField],
            [label("Atlas Cols"), columnsField],
            [label("Atlas Rows"), rowsField],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8

        let solidHint = NSTextField(labelWithString: "Click tiles below to mark them SOLID (they collide).")
        solidHint.font = NSFont.systemFont(ofSize: 10)
        solidHint.textColor = .secondaryLabelColor

        atlasView = TileAtlasView()
        atlasView.marksSolidTiles = true
        atlasView.wantsLayer = true
        atlasView.layer?.cornerRadius = 6
        atlasView.translatesAutoresizingMaskIntoConstraints = false
        atlasView.widthAnchor.constraint(equalToConstant: atlasWidth).isActive = true
        atlasHeightConstraint = atlasView.heightAnchor.constraint(equalToConstant: atlasWidth)
        atlasHeightConstraint.isActive = true
        atlasView.onSolidTilesChanged = { [weak self] solids in
            self?.statusLabel.stringValue = "\(solids.count) solid tile\(solids.count == 1 ? "" : "s") — Save Tile Set to keep."
        }

        let saveButton = NSButton(title: "Save Tile Set", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let rightStack = NSStackView(views: [grid, solidHint, atlasView, saveButton, statusLabel])
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
            leftStack.widthAnchor.constraint(equalToConstant: 190),
            listScroll.widthAnchor.constraint(equalToConstant: 190),

            rightStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            rightStack.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 24),
            rightStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        reloadAtlases()
        reloadSets()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadAtlases()
        reloadSets()
    }

    // MARK: - Tile sets

    private func reloadSets() {
        visibleSets = TileSetLibrary.list().compactMap { TileSetLibrary.tileSet(named: $0) }
        setTable.reloadData()
        if let first = visibleSets.first {
            populateFields(with: first)
            setTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func selectSet(named name: String) {
        if let row = visibleSets.firstIndex(where: { $0.name == name }) {
            setTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            populateFields(with: visibleSets[row])
        }
    }

    private func selectedSet() -> TileSetDefinition? {
        let row = setTable.selectedRow
        guard row >= 0, row < visibleSets.count else { return nil }
        return visibleSets[row]
    }

    @objc private func addSetClicked() {
        var index = 1
        var name = "tileset"
        let existing = Set(visibleSets.map { $0.name })
        while existing.contains(name) {
            index += 1
            name = "tileset\(index)"
        }
        TileSetLibrary.save(TileSetDefinition(name: name))
        reloadSets()
        selectSet(named: name)
        onLibraryChanged?()
    }

    @objc private func removeSetClicked() {
        guard let tileSet = selectedSet() else { return }
        TileSetLibrary.delete(named: tileSet.name)
        reloadSets()
        onLibraryChanged?()
    }

    @objc private func saveClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            statusLabel.stringValue = "Give the tile set a name."
            return
        }

        var tileSet = TileSetDefinition(name: name)
        tileSet.textureName = selectedAtlasName()
        tileSet.tileWidth = max(Float(tileWidthField.stringValue) ?? 32, 1)
        tileSet.tileHeight = max(Float(tileHeightField.stringValue) ?? 32, 1)
        tileSet.atlasColumns = max(Int(columnsField.stringValue) ?? 4, 1)
        tileSet.atlasRows = max(Int(rowsField.stringValue) ?? 4, 1)
        tileSet.solidTiles = atlasView.solidTiles.sorted()

        // Renaming: drop the previously selected set's old key.
        if let old = selectedSet(), old.name != name {
            TileSetLibrary.delete(named: old.name)
        }

        TileSetLibrary.save(tileSet)
        reloadSets()
        selectSet(named: name)
        statusLabel.stringValue = "Saved — apply it to a Tile Map from the Inspector or Asset Library."
        onLibraryChanged?()
    }

    private func populateFields(with tileSet: TileSetDefinition) {
        nameField.stringValue = tileSet.name
        tileWidthField.stringValue = String(format: "%.0f", tileSet.tileWidth)
        tileHeightField.stringValue = String(format: "%.0f", tileSet.tileHeight)
        columnsField.stringValue = String(tileSet.atlasColumns)
        rowsField.stringValue = String(tileSet.atlasRows)

        if let atlas = tileSet.textureName, atlasPopup.itemTitles.contains(atlas) {
            atlasPopup.selectItem(withTitle: atlas)
        } else {
            atlasPopup.selectItem(at: 0)   // "(none)"
        }

        atlasView.solidTiles = Set(tileSet.solidTiles)
        refreshAtlasView()
    }

    // MARK: - Atlas preview

    private func reloadAtlases() {
        let previous = atlasPopup.titleOfSelectedItem
        atlasPopup.removeAllItems()
        atlasPopup.addItem(withTitle: "(none)")

        guard let assetsDir = ProjectManager.shared.assetsURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: assetsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return }

        let images = files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
            .sorted()
        atlasPopup.addItems(withTitles: images)

        if let previous, atlasPopup.itemTitles.contains(previous) {
            atlasPopup.selectItem(withTitle: previous)
        }
    }

    private func selectedAtlasName() -> String? {
        guard atlasPopup.indexOfSelectedItem > 0 else { return nil }
        return atlasPopup.titleOfSelectedItem
    }

    @objc private func atlasChanged() {
        refreshAtlasView()
    }

    /// Reloads the preview image and re-shapes the grid from the
    /// current field values (fires live while typing).
    private func refreshAtlasView() {
        if let atlas = selectedAtlasName(),
           let assetsDir = ProjectManager.shared.assetsURL {
            atlasView.image = NSImage(contentsOf: assetsDir.appendingPathComponent(atlas))
        } else {
            atlasView.image = nil
        }

        let columns = max(Int(columnsField.stringValue) ?? 4, 1)
        let rows = max(Int(rowsField.stringValue) ?? 4, 1)
        atlasView.columns = columns
        atlasView.rows = rows
        atlasHeightConstraint.constant = min(max(
            atlasWidth * CGFloat(rows) / CGFloat(columns), 80), 340)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let fieldObject = obj.object as? NSTextField,
              fieldObject === columnsField || fieldObject === rowsField else { return }
        refreshAtlasView()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleSets.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < visibleSets.count else { return nil }
        let tileSet = visibleSets[row]

        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: tileSet.name)
        label.font = NSFont.systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false

        let atlasHint = NSTextField(labelWithString: tileSet.textureName ?? "no atlas")
        atlasHint.font = NSFont.systemFont(ofSize: 9)
        atlasHint.textColor = tileSet.textureName == nil ? .systemOrange : .tertiaryLabelColor
        atlasHint.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(label)
        cell.addSubview(atlasHint)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: -1),
            atlasHint.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            atlasHint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: -2),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tileSet = selectedSet() else { return }
        populateFields(with: tileSet)
    }
}
