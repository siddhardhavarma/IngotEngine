//
//  AISettingsViewController.swift
//  IngotEngine
//
//  Settings sheet for the AI copilot: provider selection, per-provider
//  model IDs, and API key management.
//
//  Keys are entered in secure fields and stored in the macOS Keychain
//  (never in source, project files, or exports). Model IDs are plain
//  preferences so users can adopt newly released models immediately.
//

import Cocoa

class AISettingsViewController: NSViewController {

    /// The settings being edited (a copy — nothing persists on Cancel).
    var settings = AISettings()

    /// Called with the saved settings when the user clicks Save.
    var onSave: ((AISettings) -> Void)?

    private var providerPopup: NSPopUpButton!
    private var statusLabel: NSTextField!

    private var openAIModelField: NSTextField!
    private var claudeModelField: NSTextField!
    private var geminiModelField: NSTextField!

    private var openAIKeyField: NSSecureTextField!
    private var claudeKeyField: NSSecureTextField!
    private var geminiKeyField: NSSecureTextField!
    private var elevenLabsKeyField: NSSecureTextField!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        // --- Provider ---
        providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: AIProvider.allCases.map { $0.displayName })
        if let index = AIProvider.allCases.firstIndex(of: settings.provider) {
            providerPopup.selectItem(at: index)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        grid.addRow(with: [makeLabel("Provider"), providerPopup])

        // --- Models + keys per provider ---
        openAIModelField = makeModelField(settings.openAIModel)
        openAIKeyField = makeKeyField(settings.openAIKey)
        grid.addRow(with: [makeHeader("OpenAI"), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel("Model"), openAIModelField])
        grid.addRow(with: [makeLabel("API Key"), openAIKeyField])

        claudeModelField = makeModelField(settings.claudeModel)
        claudeKeyField = makeKeyField(settings.claudeKey)
        grid.addRow(with: [makeHeader("Anthropic Claude"), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel("Model"), claudeModelField])
        grid.addRow(with: [makeLabel("API Key"), claudeKeyField])

        geminiModelField = makeModelField(settings.geminiModel)
        geminiKeyField = makeKeyField(settings.geminiKey)
        grid.addRow(with: [makeHeader("Google Gemini"), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel("Model"), geminiModelField])
        grid.addRow(with: [makeLabel("API Key"), geminiKeyField])

        elevenLabsKeyField = makeKeyField(settings.elevenLabsKey)
        grid.addRow(with: [makeHeader("ElevenLabs (sound gen)"), NSGridCell.emptyContentView])
        grid.addRow(with: [makeLabel("API Key"), elevenLabsKeyField])

        // --- Status + buttons ---
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [statusLabel, spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "Keys are stored in the macOS Keychain — never in project files or exports.")
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(grid)
        view.addSubview(note)
        view.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        updateStatus()
    }

    // MARK: - Row helpers

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func makeHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeModelField(_ value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.controlSize = .small
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return field
    }

    private func makeKeyField(_ value: String) -> NSSecureTextField {
        let field = NSSecureTextField(string: value)
        field.placeholderString = "not set"
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.controlSize = .small
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return field
    }

    // MARK: - Actions

    @objc private func providerChanged() {
        updateStatus()
    }

    private func updateStatus() {
        var edited = settings
        edited.provider = AIProvider.allCases[providerPopup.indexOfSelectedItem]
        readFields(into: &edited)
        statusLabel.stringValue = edited.isConfigured
            ? "✓ \(edited.provider.displayName) ready (\(edited.activeModel))"
            : "⚠ \(edited.provider.displayName) has no API key"
    }

    private func readFields(into settings: inout AISettings) {
        settings.openAIModel = openAIModelField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.claudeModel = claudeModelField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.geminiModel = geminiModelField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.openAIKey = openAIKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.claudeKey = claudeKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.geminiKey = geminiKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.elevenLabsKey = elevenLabsKeyField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func cancelClicked() {
        dismiss(self)
    }

    @objc private func saveClicked() {
        settings.provider = AIProvider.allCases[providerPopup.indexOfSelectedItem]
        readFields(into: &settings)
        settings.save()
        onSave?(settings)
        dismiss(self)
    }
}
