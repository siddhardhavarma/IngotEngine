//
//  TileSetEditorViewController.swift
//  IngotEngine
//
//  §5.8 — The Tile Set editor (its own window, like Animations).
//
//  A tile set bundles everything a tile map needs: the atlas image,
//  its grid, the world size of one tile, which tiles are solid, and
//  named CATEGORIES that group tiles ("Ground", "Hazards", "Decor")
//  the way a character groups its animation clips.
//
//  The workflow is visual: pick the atlas and enter the tile size —
//  the grid (cols × rows) is computed from the image's pixel size
//  automatically — then choose what clicking assigns (Solid or a
//  category) and click cells in the preview. Saved sets live in
//  tilesets.json and apply to any TileMapNode from the Inspector's
//  Tile Set popup, the Asset Library (double-click), or the AI
//  (configureTileMap + "tileSet").
//
//    Left:  saved tile sets (+/−)
//    Right: atlas + tile size (grid auto-computed), the "click
//           assigns" target, and the clickable atlas preview
//

import Cocoa

// ---------------------------------------------------------------------------
// TileAtlasView — a clickable atlas grid, shared by this editor (mark
// solid tiles / categories) and the Inspector's paint palette
// ---------------------------------------------------------------------------

class TileAtlasView: NSView {

    /// The atlas image, drawn stretched to the view's bounds.
    var image: NSImage? { didSet { needsDisplay = true } }
    var columns = 4 { didSet { columns = max(columns, 1); needsDisplay = true } }
    var rows = 4 { didSet { rows = max(rows, 1); needsDisplay = true } }

    /// Passive markers for orientation (tile index → color): solid
    /// tiles, category members. Drawn as a light fill + thin border.
    var overlays: [Int: NSColor] = [:] { didSet { needsDisplay = true } }

    /// true → clicking toggles membership in `editingTiles` (the tile
    /// set editor); false → clicking picks one index (paint palette).
    var isEditable = false

    /// The group currently being click-edited, drawn stronger than
    /// the overlays in `editingColor`.
    var editingTiles: Set<Int> = [] { didSet { needsDisplay = true } }
    var editingColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    var onEditingTilesChanged: ((Set<Int>) -> Void)?

    /// Palette mode: the currently picked index (-1 = none).
    var selectedIndex = -1 { didSet { needsDisplay = true } }
    var onTilePicked: ((Int) -> Void)?

    /// A stable color per category slot (used by the editor and the
    /// Inspector palette so both show the same hues).
    static func categoryColor(_ index: Int) -> NSColor {
        let palette: [NSColor] = [.systemOrange, .systemGreen, .systemBlue,
                                  .systemPurple, .systemPink, .systemTeal,
                                  .systemYellow, .systemBrown]
        return palette[index % palette.count]
    }

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

        // Passive overlays (dimmer).
        for (index, color) in overlays where index >= 0 && index < columns * rows {
            let rect = cellRect(index: index, cellW: cellW, cellH: cellH)
            color.withAlphaComponent(0.16).setFill()
            rect.fill(using: .sourceOver)
            color.withAlphaComponent(0.6).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 1
            border.stroke()
        }

        // The actively edited group (stronger).
        for index in editingTiles where index >= 0 && index < columns * rows {
            let rect = cellRect(index: index, cellW: cellW, cellH: cellH)
            editingColor.withAlphaComponent(0.3).setFill()
            rect.fill(using: .sourceOver)
            editingColor.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 1.5
            border.stroke()
        }

        // Palette selection.
        if !isEditable, selectedIndex >= 0, selectedIndex < columns * rows {
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

        if isEditable {
            if editingTiles.contains(index) {
                editingTiles.remove(index)
            } else {
                editingTiles.insert(index)
            }
            onEditingTilesChanged?(editingTiles)
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
    private var markTargetPopup: NSPopUpButton!
    private var statusLabel: NSTextField!

    // --- Atlas preview ---
    private var atlasView: TileAtlasView!
    private var atlasHeightConstraint: NSLayoutConstraint!
    private let atlasWidth: CGFloat = 440

    /// The atlas image's true pixel size (for grid auto-compute).
    private var atlasPixelSize: (width: Int, height: Int)?

    // --- Marker state (what clicking assigns) ---

    /// Tiles marked solid (collision).
    private var solidTiles: Set<Int> = []

    /// Named tile groups, edited in place and saved with the set.
    private var categories: [String: Set<Int>] = [:]

    /// nil = clicking marks Solid; otherwise the category being edited.
    private var activeCategory: String?

    // MARK: - Layout

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 620))
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

        tileWidthField = field("16")
        tileHeightField = field("16")
        columnsField = field("16")
        rowsField = field("16")

        let gridHint = NSTextField(labelWithString: "(computed from the image ÷ tile size — override if needed)")
        gridHint.font = NSFont.systemFont(ofSize: 9)
        gridHint.textColor = .tertiaryLabelColor

        markTargetPopup = NSPopUpButton()
        markTargetPopup.controlSize = .small
        markTargetPopup.target = self
        markTargetPopup.action = #selector(markTargetChanged)

        let form = NSGridView(views: [
            [label("Name"), nameField],
            [label("Atlas Image"), atlasPopup],
            [label("Tile W (px)"), tileWidthField],
            [label("Tile H (px)"), tileHeightField],
            [label("Atlas Cols"), columnsField],
            [label("Atlas Rows"), rowsField],
            [NSGridCell.emptyContentView, gridHint],
            [label("Click assigns"), markTargetPopup],
        ])
        form.rowSpacing = 6
        form.columnSpacing = 8

        atlasView = TileAtlasView()
        atlasView.isEditable = true
        atlasView.wantsLayer = true
        atlasView.layer?.cornerRadius = 6
        atlasView.translatesAutoresizingMaskIntoConstraints = false
        atlasView.widthAnchor.constraint(equalToConstant: atlasWidth).isActive = true
        atlasHeightConstraint = atlasView.heightAnchor.constraint(equalToConstant: atlasWidth)
        atlasHeightConstraint.isActive = true
        atlasView.onEditingTilesChanged = { [weak self] tiles in
            self?.editingTilesChanged(tiles)
        }

        let saveButton = NSButton(title: "Save Tile Set", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let rightStack = NSStackView(views: [form, atlasView, saveButton, statusLabel])
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
        tileSet.solidTiles = solidTiles.sorted()
        let nonEmpty = categories.filter { !$0.value.isEmpty }
        tileSet.categories = nonEmpty.isEmpty
            ? nil : nonEmpty.mapValues { $0.sorted() }

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

        solidTiles = Set(tileSet.solidTiles)
        categories = (tileSet.categories ?? [:]).mapValues { Set($0) }
        activeCategory = nil

        refreshAtlasImage()
        rebuildMarkTargetPopup()
        refreshAtlasView()
    }

    // MARK: - Marker targets (Solid / categories)

    private func sortedCategoryNames() -> [String] {
        categories.keys.sorted()
    }

    private func rebuildMarkTargetPopup() {
        markTargetPopup.removeAllItems()
        markTargetPopup.addItem(withTitle: "Solid (collision)")
        markTargetPopup.addItems(withTitles: sortedCategoryNames())
        markTargetPopup.menu?.addItem(.separator())
        markTargetPopup.addItem(withTitle: "New Category…")

        if let active = activeCategory, markTargetPopup.itemTitles.contains(active) {
            markTargetPopup.selectItem(withTitle: active)
        } else {
            activeCategory = nil
            markTargetPopup.selectItem(at: 0)
        }
    }

    @objc private func markTargetChanged() {
        let title = markTargetPopup.titleOfSelectedItem ?? ""

        if title == "New Category…" {
            promptNewCategory()
            return
        }

        activeCategory = title == "Solid (collision)" ? nil : title
        refreshAtlasView()
    }

    private func promptNewCategory() {
        let alert = NSAlert()
        alert.messageText = "New Tile Category"
        alert.informativeText = "A category groups related tiles (Ground, Hazards, Decor…) — like a character groups its animations."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameInput = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        nameInput.placeholderString = "Ground"
        alert.accessoryView = nameInput
        alert.window.initialFirstResponder = nameInput

        let created: String?
        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameInput.stringValue.trimmingCharacters(in: .whitespaces)
            created = name.isEmpty ? nil : name
        } else {
            created = nil
        }

        if let created {
            if categories[created] == nil { categories[created] = [] }
            activeCategory = created
        }
        rebuildMarkTargetPopup()
        refreshAtlasView()
    }

    private func editingTilesChanged(_ tiles: Set<Int>) {
        if let active = activeCategory {
            categories[active] = tiles
        } else {
            solidTiles = tiles
        }
        let targetName = activeCategory ?? "Solid"
        statusLabel.stringValue = "\(tiles.count) tile\(tiles.count == 1 ? "" : "s") in \(targetName) — Save Tile Set to keep."
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
        refreshAtlasImage()
        autoFillGrid()
        refreshAtlasView()
    }

    /// Loads the preview image and records its true pixel size (via
    /// CGImage — NSImage.size reports points, which lies for high-DPI
    /// files).
    private func refreshAtlasImage() {
        atlasPixelSize = nil
        atlasView.image = nil
        guard let atlas = selectedAtlasName(),
              let assetsDir = ProjectManager.shared.assetsURL,
              let image = NSImage(contentsOf: assetsDir.appendingPathComponent(atlas)) else {
            return
        }
        atlasView.image = image
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            atlasPixelSize = (cg.width, cg.height)
        }
    }

    /// Computes Atlas Cols/Rows from the image's pixel size and the
    /// tile size — the step everyone gets wrong when typing by hand.
    private func autoFillGrid() {
        guard let (width, height) = atlasPixelSize else { return }
        let tileW = max(Float(tileWidthField.stringValue) ?? 16, 1)
        let tileH = max(Float(tileHeightField.stringValue) ?? 16, 1)
        columnsField.stringValue = String(max(Int((Float(width) / tileW).rounded()), 1))
        rowsField.stringValue = String(max(Int((Float(height) / tileH).rounded()), 1))
    }

    /// Re-shapes the grid + markers from the current state.
    private func refreshAtlasView() {
        let columns = max(Int(columnsField.stringValue) ?? 4, 1)
        let rows = max(Int(rowsField.stringValue) ?? 4, 1)
        atlasView.columns = columns
        atlasView.rows = rows
        atlasHeightConstraint.constant = min(max(
            atlasWidth * CGFloat(rows) / CGFloat(columns), 120), 440)

        // Passive overlays: every non-active group, each in its color.
        var overlays: [Int: NSColor] = [:]
        let names = sortedCategoryNames()
        for (index, name) in names.enumerated() where name != activeCategory {
            for tile in categories[name] ?? [] {
                overlays[tile] = TileAtlasView.categoryColor(index)
            }
        }
        if activeCategory != nil {
            for tile in solidTiles { overlays[tile] = .systemRed }
        }
        atlasView.overlays = overlays

        // The actively edited group.
        if let active = activeCategory {
            atlasView.editingTiles = categories[active] ?? []
            atlasView.editingColor = TileAtlasView.categoryColor(
                names.firstIndex(of: active) ?? 0)
        } else {
            atlasView.editingTiles = solidTiles
            atlasView.editingColor = .systemRed
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let fieldObject = obj.object as? NSTextField else { return }
        if fieldObject === tileWidthField || fieldObject === tileHeightField {
            autoFillGrid()
            refreshAtlasView()
        } else if fieldObject === columnsField || fieldObject === rowsField {
            refreshAtlasView()
        }
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
