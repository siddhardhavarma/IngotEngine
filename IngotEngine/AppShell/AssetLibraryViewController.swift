//
//  AssetLibraryViewController.swift
//  IngotEngine
//
//  §5.6 — The asset library (left dock, below the scene hierarchy).
//
//  The hub of the asset workflow:
//
//    Import…      → copies files (png/jpg/wav/mp3) into the project's
//                   Assets/ folder
//    Textures     → double-click assigns the image to the selected
//                   Sprite/Shape/TileMap (records textureName so it
//                   persists through save/load and export)
//    Audio        → double-click assigns the file to a selected
//                   AudioNode's soundFile
//    Prefabs      → double-click places an instance in the scene
//
//  Thumbnails preview image assets in place, so users can see their
//  art without leaving the editor.
//

import Cocoa
import MetalKit
import UniformTypeIdentifiers

class AssetLibraryViewController: NSViewController,
                                  NSTableViewDataSource,
                                  NSTableViewDelegate {

    /// One row in the library.
    private struct AssetItem {
        enum Kind { case texture, audio, script, prefab, animation }
        let kind: Kind
        let name: String
        let url: URL?          // nil for prefabs/animations (load by name)
        let subtitle: String
    }

    // --- Callbacks to the editor shell ---

    /// Double-click on a texture: assign to the current selection.
    var onAssignTexture: ((URL) -> Void)?

    /// Double-click on an audio file: assign to a selected AudioNode.
    var onAssignAudio: ((String) -> Void)?

    /// Double-click on a script: assign to the selection (if any) and
    /// open it in the Script Editor.
    var onOpenScript: ((String) -> Void)?

    /// Double-click on a prefab: instantiate it in the scene.
    var onPlacePrefab: ((String) -> Void)?

    /// Double-click on an animation clip: open the Animations window.
    var onOpenAnimations: (() -> Void)?

    /// Status/log line (routed to the AI chat history).
    var onLog: ((String) -> Void)?

    private var tableView: NSTableView!
    private var filterPopup: NSPopUpButton!
    private var items: [AssetItem] = []

    private let filterTitles = ["All", "Art", "Audio", "Scripts", "Prefabs", "Animations"]

    // MARK: - Layout

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        self.view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = NSTextField(labelWithString: "ASSET LIBRARY")
        header.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        header.textColor = .tertiaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        filterPopup = NSPopUpButton()
        filterPopup.addItems(withTitles: filterTitles)
        filterPopup.controlSize = .small
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        filterPopup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filterPopup)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.style = .sourceList
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Asset"))
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let importButton = NSButton(title: "Import…", target: self,
                                    action: #selector(importClicked))
        importButton.bezelStyle = .rounded
        importButton.controlSize = .small

        let hint = NSTextField(labelWithString: "Double-click assigns to the selection")
        hint.font = NSFont.systemFont(ofSize: 9)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let bottomBar = NSStackView(views: [importButton, hint])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 6
        bottomBar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 5, right: 8)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            filterPopup.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            filterPopup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            filterPopup.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: filterPopup.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    // MARK: - Content

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
    private static let audioExtensions: Set<String> = ["wav", "mp3", "aac", "m4a"]

    /// Re-reads Assets/, Scripts/, Prefabs/, and the animation library.
    func refresh() {
        guard isViewLoaded else { return }
        items.removeAll()

        let fm = FileManager.default
        let filter = filterPopup.indexOfSelectedItem

        if let assetsDir = ProjectManager.shared.assetsURL,
           let files = try? fm.contentsOfDirectory(at: assetsDir,
                                                   includingPropertiesForKeys: [.fileSizeKey],
                                                   options: .skipsHiddenFiles) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = file.pathExtension.lowercased()
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let subtitle = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)

                if Self.imageExtensions.contains(ext), filter == 0 || filter == 1 {
                    items.append(AssetItem(kind: .texture, name: file.lastPathComponent,
                                           url: file, subtitle: subtitle))
                } else if Self.audioExtensions.contains(ext), filter == 0 || filter == 2 {
                    items.append(AssetItem(kind: .audio, name: file.lastPathComponent,
                                           url: file, subtitle: subtitle))
                }
            }
        }

        if filter == 0 || filter == 3 {
            for script in ProjectManager.shared.listScripts() {
                items.append(AssetItem(kind: .script, name: script,
                                       url: nil, subtitle: "Script — double-click to edit/assign"))
            }
        }

        if filter == 0 || filter == 4 {
            for prefab in PrefabLibrary.list() {
                items.append(AssetItem(kind: .prefab, name: prefab,
                                       url: nil, subtitle: "Prefab"))
            }
        }

        if filter == 0 || filter == 5 {
            for clip in AnimationLibrary.list() {
                items.append(AssetItem(kind: .animation, name: clip,
                                       url: nil, subtitle: "Animation clip"))
            }
        }

        tableView.reloadData()
    }

    @objc private func filterChanged() {
        refresh()
    }

    // MARK: - Import

    @objc private func importClicked() {
        guard let assetsDir = ProjectManager.shared.assetsURL else {
            onLog?("No project open — cannot import assets.")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Assets"
        panel.message = "Pick files OR whole folders — images (png/jpg) and audio (wav/mp3) inside are copied into the project's Assets folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK else { return }

            var imported = 0
            var skipped = 0
            for source in panel.urls {
                self.importItem(at: source, into: assetsDir,
                                imported: &imported, skipped: &skipped)
            }

            var message = "Imported \(imported) asset\(imported == 1 ? "" : "s")."
            if skipped > 0 {
                message += " Skipped \(skipped) unsupported file\(skipped == 1 ? "" : "s")."
            }
            self.onLog?(message)
            self.refresh()
        }
    }

    /// Copies a file into Assets/, or recurses through a folder copying
    /// every supported file inside it (flattened — the engine resolves
    /// assets by file name).
    private func importItem(at url: URL, into assetsDir: URL,
                            imported: inout Int, skipped: inout Int) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            guard let children = try? fm.contentsOfDirectory(at: url,
                                                             includingPropertiesForKeys: nil,
                                                             options: .skipsHiddenFiles) else { return }
            for child in children {
                importItem(at: child, into: assetsDir,
                           imported: &imported, skipped: &skipped)
            }
            return
        }

        let ext = url.pathExtension.lowercased()
        guard Self.imageExtensions.contains(ext) || Self.audioExtensions.contains(ext) else {
            skipped += 1
            return
        }

        let dest = assetsDir.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        if (try? fm.copyItem(at: url, to: dest)) != nil {
            imported += 1
        }
    }

    // MARK: - Assignment

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]

        switch item.kind {
        case .texture:
            if let url = item.url { onAssignTexture?(url) }
        case .audio:
            onAssignAudio?(item.name)
        case .script:
            onOpenScript?(item.name)
        case .prefab:
            onPlacePrefab?(item.name)
        case .animation:
            onOpenAnimations?()
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let cell = NSTableCellView()

        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false

        switch item.kind {
        case .texture:
            // Real thumbnail of the image asset.
            if let url = item.url, let image = NSImage(contentsOf: url) {
                thumb.image = image
            } else {
                thumb.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            }
        case .audio:
            thumb.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            thumb.contentTintColor = .systemTeal
        case .script:
            thumb.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil)
            thumb.contentTintColor = .systemPurple
        case .prefab:
            thumb.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
            thumb.contentTintColor = .systemOrange
        case .animation:
            thumb.image = NSImage(systemSymbolName: "figure.walk.motion", accessibilityDescription: nil)
            thumb.contentTintColor = .systemGreen
        }

        let nameLabel = NSTextField(labelWithString: item.name)
        nameLabel.font = NSFont.systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: item.subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 9)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(thumb)
        cell.addSubview(nameLabel)
        cell.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            thumb.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 26),
            thumb.heightAnchor.constraint(equalToConstant: 26),

            nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
            subtitleLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 6),
        ])

        return cell
    }
}
