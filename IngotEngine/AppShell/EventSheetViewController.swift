//
//  EventSheetViewController.swift
//  IngotEngine
//
//  §5.4 Behavior Editor — The visual scripting surface.
//
//  Displays a node's behavior rules as rows in a table:
//
//    ┌──────────────────────────┬──────────────────────────────┐
//    │  WHEN                    │  DO                          │
//    ├──────────────────────────┼──────────────────────────────┤
//    │  [Action Held ▼] move_r  │  [Move ▼] X: 300  Y: 0     │
//    │  [Every Frame ▼]         │  [Rotate ▼] 45°/s           │
//    │  [On Collision ▼]        │  [Emit Signal ▼] "bounce"   │
//    └──────────────────────────┴──────────────────────────────┘
//    [+ Add Rule]
//
//  Each row maps directly to a Rule struct. The editor builds Rules
//  from the UI widgets and attaches them as a Behavior to the node.
//

import Cocoa

class EventSheetViewController: NSViewController {

    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var addRuleButton: NSButton!

    /// The node whose rules are being edited.
    var targetNode: Node? {
        didSet { rebuildUI() }
    }

    /// Called before any edit so the editor can save an undo snapshot.
    var onBeforeEdit: (() -> Void)?

    // The event types available in the dropdown.
    private let eventTypes = ["Action Held", "Every Frame", "On Start", "On Collision", "On Signal"]
    // The action types available in the dropdown.
    private let actionTypes = ["Move", "Rotate", "Emit Signal", "Play Sound", "Set Property", "Destroy"]

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.wantsLayer = true

        // Header.
        let header = NSTextField(labelWithString: "Event Sheet")
        header.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        // Stack view holds the rule rows.
        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Add Rule button.
        addRuleButton = NSButton(title: "+ Add Rule", target: self, action: #selector(addRuleClicked))
        addRuleButton.bezelStyle = .rounded
        addRuleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addRuleButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: addRuleButton.topAnchor, constant: -8),

            addRuleButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            addRuleButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    /// Rebuilds the UI from the target node's current rules.
    func rebuildUI() {
        guard isViewLoaded else { return }

        // Clear existing rows.
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let node = targetNode else { return }

        // Find the first non-script Behavior (the rule-based one).
        let behavior = node.behaviors.first { !($0 is ScriptBehavior) }

        guard let rules = behavior?.rules, !rules.isEmpty else {
            let emptyLabel = NSTextField(labelWithString: "No rules. Click + to add one.")
            emptyLabel.font = NSFont.systemFont(ofSize: 12)
            emptyLabel.textColor = .tertiaryLabelColor
            stackView.addArrangedSubview(emptyLabel)
            return
        }

        for (index, rule) in rules.enumerated() {
            let row = createRuleRow(rule: rule, index: index)
            stackView.addArrangedSubview(row)
        }
    }

    // MARK: - Rule row creation

    private func createRuleRow(rule: Rule, index: Int) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.3).cgColor
        container.layer?.cornerRadius = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        // "When" label.
        let whenLabel = NSTextField(labelWithString: "When:")
        whenLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        whenLabel.textColor = .systemBlue
        whenLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(whenLabel)

        // Event description.
        let eventLabel = NSTextField(labelWithString: rule.event.displayName)
        eventLabel.font = NSFont.systemFont(ofSize: 12)
        eventLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(eventLabel)

        // "Do" label.
        let doLabel = NSTextField(labelWithString: "Do:")
        doLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        doLabel.textColor = .systemGreen
        doLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(doLabel)

        // Action descriptions.
        let actionsText = rule.actions.map { $0.displayName }.joined(separator: ", ")
        let actionsLabel = NSTextField(labelWithString: actionsText)
        actionsLabel.font = NSFont.systemFont(ofSize: 12)
        actionsLabel.lineBreakMode = .byWordWrapping
        actionsLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(actionsLabel)

        // Delete button.
        let deleteButton = NSButton(title: "×", target: self, action: #selector(deleteRuleClicked(_:)))
        deleteButton.bezelStyle = .smallSquare
        deleteButton.isBordered = false
        deleteButton.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        deleteButton.tag = index
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            whenLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            whenLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            whenLabel.widthAnchor.constraint(equalToConstant: 40),

            eventLabel.centerYAnchor.constraint(equalTo: whenLabel.centerYAnchor),
            eventLabel.leadingAnchor.constraint(equalTo: whenLabel.trailingAnchor, constant: 4),
            eventLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -4),

            doLabel.topAnchor.constraint(equalTo: whenLabel.bottomAnchor, constant: 2),
            doLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            doLabel.widthAnchor.constraint(equalToConstant: 40),
            doLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),

            actionsLabel.centerYAnchor.constraint(equalTo: doLabel.centerYAnchor),
            actionsLabel.leadingAnchor.constraint(equalTo: doLabel.trailingAnchor, constant: 4),
            actionsLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -4),

            deleteButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            deleteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            deleteButton.widthAnchor.constraint(equalToConstant: 20),
        ])

        // Make the row fill the stack view's width.
        container.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -8).isActive = true

        return container
    }

    // MARK: - Actions

    @objc private func addRuleClicked() {
        guard let node = targetNode else { return }
        onBeforeEdit?()

        // Add a default "Every Frame → Move" rule.
        let newRule = Rule(event: .everyFrame, actions: [.move(x: 0, y: 0)])

        // Find the existing rule behavior, or create one.
        if let behavior = node.behaviors.first(where: { !($0 is ScriptBehavior) }) {
            behavior.rules.append(newRule)
        } else {
            let behavior = Behavior(rules: [newRule])
            node.addBehavior(behavior)
        }

        rebuildUI()
    }

    @objc private func deleteRuleClicked(_ sender: NSButton) {
        guard let node = targetNode else { return }
        onBeforeEdit?()

        let index = sender.tag
        if let behavior = node.behaviors.first(where: { !($0 is ScriptBehavior) }),
           index < behavior.rules.count {
            behavior.rules.remove(at: index)
        }

        rebuildUI()
    }
}
