//
//  AssetBrowserViewController.swift
//  IngotEngine
//
//  Project file browser with type icons, headers, and refresh.
//

import Cocoa

class AssetBrowserViewController: NSViewController,
                                   NSTableViewDataSource,
                                   NSTableViewDelegate {

    private var tableView: NSTableView!
    private var files: [URL] = []
    private var emptyLabel: NSTextField!

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // --- Table view with visible headers ---
        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = .solidHorizontalGridLineMask

        let iconCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Icon"))
        iconCol.title = ""
        iconCol.width = 24
        iconCol.maxWidth = 24
        tableView.addTableColumn(iconCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileName"))
        nameCol.title = "Name"
        nameCol.minWidth = 150
        tableView.addTableColumn(nameCol)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileType"))
        typeCol.title = "Type"
        typeCol.width = 60
        typeCol.maxWidth = 80
        tableView.addTableColumn(typeCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileSize"))
        sizeCol.title = "Size"
        sizeCol.width = 70
        sizeCol.maxWidth = 90
        tableView.addTableColumn(sizeCol)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Refresh button.
        let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
                                     target: self, action: #selector(refreshFiles))
        refreshButton.bezelStyle = .smallSquare
        refreshButton.isBordered = false
        refreshButton.toolTip = "Refresh file list"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(refreshButton)

        // Empty state label.
        emptyLabel = NSTextField(labelWithString: "No project files yet.\nGenerate assets with the AI Copilot\nor import files into Assets/.")
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            refreshButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        refreshFiles()
    }

    @objc func refreshFiles() {
        files.removeAll()

        let fm = FileManager.default
        let extensions = Set(["png", "jpg", "jpeg", "wav", "mp3", "aac", "json", "js"])

        if let assetsDir = ProjectManager.shared.assetsURL {
            scanDirectory(assetsDir, extensions: extensions, fm: fm)
        }
        if let scriptsDir = ProjectManager.shared.scriptsURL {
            scanDirectory(scriptsDir, extensions: extensions, fm: fm)
        }
        if let scenesDir = ProjectManager.shared.scenesURL {
            scanDirectory(scenesDir, extensions: extensions, fm: fm)
        }

        files.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        emptyLabel?.isHidden = !files.isEmpty
        tableView?.reloadData()
    }

    private func scanDirectory(_ dir: URL, extensions: Set<String>, fm: FileManager) {
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                          options: .skipsHiddenFiles) else { return }
        for url in contents {
            if extensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
    }

    private func iconForExtension(_ ext: String) -> NSImage? {
        let symbol: String
        switch ext.lowercased() {
        case "png", "jpg", "jpeg": symbol = "photo"
        case "wav", "mp3", "aac":  symbol = "speaker.wave.2"
        case "js":                  symbol = "scroll"
        case "json":                symbol = "doc.text"
        default:                    symbol = "doc"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < files.count else { return nil }

        let file = files[row]
        let cellID = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("Cell")

        if cellID.rawValue == "Icon" {
            var iv = tableView.makeView(withIdentifier: cellID, owner: self) as? NSImageView
            if iv == nil {
                iv = NSImageView()
                iv?.identifier = cellID
            }
            iv?.image = iconForExtension(file.pathExtension)
            iv?.contentTintColor = .secondaryLabelColor
            return iv
        }

        var cellView = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView

        if cellView == nil {
            let cell = NSTableCellView()
            cell.identifier = cellID

            let textField = NSTextField(labelWithString: "")
            textField.font = NSFont.systemFont(ofSize: 11)
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            cellView = cell
        }

        switch cellID.rawValue {
        case "FileName":
            cellView?.textField?.stringValue = file.lastPathComponent
        case "FileType":
            cellView?.textField?.stringValue = file.pathExtension.uppercased()
            cellView?.textField?.textColor = .secondaryLabelColor
        case "FileSize":
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            cellView?.textField?.stringValue = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            cellView?.textField?.textColor = .secondaryLabelColor
        default:
            break
        }

        return cellView
    }
}
