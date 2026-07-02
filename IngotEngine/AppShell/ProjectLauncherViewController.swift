//
//  ProjectLauncherViewController.swift
//  IngotEngine
//
//  §5.1 — The project launcher (what users see at startup).
//
//  Like Godot's Project Manager or Unity Hub: a window listing recent
//  projects (double-click to open) with New Project… and Open… actions.
//  Replaces the bare folder-picker dialog the app used to open with.
//
//  Recents are stored as paths in UserDefaults; entries whose folders
//  no longer exist are filtered out on load.
//

import Cocoa

class ProjectLauncherViewController: NSViewController,
                                     NSTableViewDataSource,
                                     NSTableViewDelegate {

    /// Called with the chosen/created project directory.
    var onProjectChosen: ((URL) -> Void)?

    private var tableView: NSTableView!
    private var recents: [URL] = []

    // MARK: - Recent project bookkeeping

    private static let recentsKey = "RecentProjects"
    private static let maxRecents = 10

    static func loadRecents() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func addRecent(_ url: URL) {
        var paths = (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(maxRecents)), forKey: recentsKey)
    }

    // MARK: - Layout

    override func loadView() {
        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        effectView.material = .windowBackground
        effectView.blendingMode = .behindWindow
        self.view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // --- Branding column (left) ---
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "cube.transparent",
                             accessibilityDescription: "Ingot Engine")?
            .withSymbolConfiguration(.init(pointSize: 56, weight: .thin))
        icon.contentTintColor = .systemOrange

        let title = NSTextField(labelWithString: "Ingot Engine")
        title.font = NSFont.systemFont(ofSize: 26, weight: .bold)

        let subtitle = NSTextField(labelWithString: "AI-native 2D games for iPhone, iPad & Apple TV")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let newButton = NSButton(title: "New Project…", target: self,
                                 action: #selector(newProjectClicked))
        newButton.bezelStyle = .rounded
        newButton.keyEquivalent = "n"
        newButton.keyEquivalentModifierMask = [.command]

        let openButton = NSButton(title: "Open Existing…", target: self,
                                  action: #selector(openExistingClicked))
        openButton.bezelStyle = .rounded

        let brandStack = NSStackView(views: [icon, title, subtitle, newButton, openButton])
        brandStack.orientation = .vertical
        brandStack.alignment = .centerX
        brandStack.spacing = 12
        brandStack.setCustomSpacing(28, after: subtitle)
        brandStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Recents column (right) ---
        let recentsHeader = NSTextField(labelWithString: "RECENT PROJECTS")
        recentsHeader.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        recentsHeader.textColor = .tertiaryLabelColor
        recentsHeader.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.style = .inset
        tableView.doubleAction = #selector(recentDoubleClicked)
        tableView.target = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Project"))
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(brandStack)
        view.addSubview(divider)
        view.addSubview(recentsHeader)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            brandStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            brandStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            brandStack.widthAnchor.constraint(equalToConstant: 240),

            divider.leadingAnchor.constraint(equalTo: brandStack.trailingAnchor, constant: 24),
            divider.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            recentsHeader.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            recentsHeader.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: recentsHeader.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        reloadRecents()
    }

    private func reloadRecents() {
        recents = Self.loadRecents()
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func newProjectClicked() {
        let panel = NSSavePanel()
        panel.title = "New Ingot Project"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = "MyGame"
        panel.canCreateDirectories = true

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            self?.onProjectChosen?(url)
        }
    }

    @objc private func openExistingClicked() {
        let panel = NSOpenPanel()
        panel.title = "Open Ingot Project"
        panel.message = "Choose a project folder (contains project.json)."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open"

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.onProjectChosen?(url)
        }
    }

    @objc private func recentDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < recents.count else { return }
        onProjectChosen?(recents[row])
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        recents.isEmpty ? 1 : recents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {

        // Empty state.
        if recents.isEmpty {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: "No recent projects yet.")
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = .tertiaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        let url = recents[row]

        let cell = NSTableCellView()

        let nameLabel = NSTextField(labelWithString: url.lastPathComponent)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: url.deletingLastPathComponent().path)
        pathLabel.font = NSFont.systemFont(ofSize: 10)
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(nameLabel)
        cell.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),

            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            pathLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
        ])

        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !recents.isEmpty
    }
}
