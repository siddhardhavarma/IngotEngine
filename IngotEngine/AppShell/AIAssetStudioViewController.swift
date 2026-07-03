//
//  AIAssetStudioViewController.swift
//  IngotEngine
//
//  §5.9 — The AI Asset Studio (a tab in the logic dock, next to the
//  Event Sheet and Script Editor).
//
//  Purpose-built generation for game assets — instead of describing
//  assets to the chat copilot, pick WHAT you're making and the studio
//  scaffolds the prompt for that asset class:
//
//    Images (DALL·E 3): textures/tiles, character sprites, sprite
//    sheets, effects, backgrounds, UI elements — with size presets
//    and an optional pixel-art style toggle.
//    Sounds (ElevenLabs): sound effects, ambient loops, UI feedback —
//    with a duration control.
//
//  Results save straight into the project's Assets/ folder under the
//  name you chose (so textureName persistence and exports just work),
//  appear in the Asset Library immediately, preview in place, and can
//  be assigned to the current selection with one click.
//
//  Keys come from ✦ AI Settings (Keychain) — never stored here.
//

import Cocoa
import AVFoundation

class AIAssetStudioViewController: NSViewController {

    // --- Injected by the editor shell ---

    var generator: AssetGenerator?
    var audioManager: AudioManager?
    var settingsProvider: (() -> AISettings)?

    /// Status line (routed to the AI chat history).
    var onLog: ((String) -> Void)?

    /// Fired after a file lands in Assets/ so the library refreshes.
    var onAssetsChanged: (() -> Void)?

    /// One-click assignment to the current selection.
    var onAssignTexture: ((URL) -> Void)?
    var onAssignAudio: ((String) -> Void)?

    // --- Controls ---

    private var modeControl: NSSegmentedControl!
    private var typePopup: NSPopUpButton!
    private var promptField: NSTextField!
    private var sizeLabel: NSTextField!
    private var sizePopup: NSPopUpButton!
    private var pixelArtCheckbox: NSButton!
    private var durationLabel: NSTextField!
    private var durationField: NSTextField!
    private var nameField: NSTextField!
    private var generateButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var hintLabel: NSTextField!

    private var previewImage: NSImageView!
    private var playButton: NSButton!
    private var assignButton: NSButton!
    private var formGrid: NSGridView!

    private var lastGeneratedFile: String?

    private var isImageMode: Bool { modeControl.selectedSegment == 0 }

    // --- Prompt scaffolding per asset class ---
    // The suffix steers the model toward usable GAME art: filled
    // frames for tiles, plain backgrounds for sprites (DALL·E can't
    // do true transparency), strict grids for sheets.

    private let imageTypes: [(title: String, suffix: String)] = [
        ("Texture / Tile",
         ", seamless tileable 2D game texture, fills the entire frame edge to edge, no borders, no text"),
        ("Character Sprite",
         ", 2D game character sprite, full body, centered on a plain flat single-color background, no text"),
        ("Sprite Sheet",
         ", 2D game animation sprite sheet, frames of the same character arranged in one strict uniform grid, plain flat background, no text"),
        ("Effect / Particle",
         ", 2D game visual effect sprite, glowing on a plain black background, no text"),
        ("Background",
         ", 2D game background art, wide composition, no characters, no text"),
        ("UI Element",
         ", flat 2D game user-interface element, centered on a plain background, no text"),
        ("Custom (raw prompt)", ""),
    ]

    private let soundTypes: [(title: String, suffix: String)] = [
        ("Sound Effect", ", short punchy video game sound effect"),
        ("Ambience / Loop", ", ambient background loop for a video game"),
        ("UI / Feedback", ", short subtle interface feedback sound"),
        ("Custom (raw prompt)", ""),
    ]

    // MARK: - Layout

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .underPageBackground
        effectView.blendingMode = .behindWindow
        self.view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        modeControl = NSSegmentedControl(labels: ["Image", "Sound"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(modeChanged))
        modeControl.selectedSegment = 0
        modeControl.controlSize = .small

        func rowLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }

        typePopup = NSPopUpButton()
        typePopup.controlSize = .small
        typePopup.target = self
        typePopup.action = #selector(typeChanged)

        promptField = NSTextField()
        promptField.placeholderString = "molten lava rock with glowing cracks"
        promptField.controlSize = .small
        promptField.font = NSFont.systemFont(ofSize: 12)
        promptField.lineBreakMode = .byWordWrapping
        promptField.usesSingleLineMode = false
        promptField.cell?.wraps = true
        promptField.cell?.isScrollable = false
        promptField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        promptField.heightAnchor.constraint(equalToConstant: 48).isActive = true

        sizeLabel = rowLabel("Size")
        sizePopup = NSPopUpButton()
        sizePopup.controlSize = .small
        sizePopup.addItems(withTitles: ["1024 × 1024", "1792 × 1024 (wide)", "1024 × 1792 (tall)"])

        pixelArtCheckbox = NSButton(checkboxWithTitle: "Pixel art style", target: nil, action: nil)
        pixelArtCheckbox.controlSize = .small

        durationLabel = rowLabel("Duration (s)")
        durationField = NSTextField()
        durationField.stringValue = "2.0"
        durationField.placeholderString = "0.5 – 22"
        durationField.controlSize = .small
        durationField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        nameField = NSTextField()
        nameField.placeholderString = "lava_tile.png (blank = auto)"
        nameField.controlSize = .small
        nameField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        generateButton = NSButton(title: "✦ Generate", target: self, action: #selector(generateClicked))
        generateButton.bezelStyle = .rounded
        generateButton.controlSize = .small
        generateButton.keyEquivalent = "\r"

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        hintLabel = NSTextField(wrappingLabelWithString: "")
        hintLabel.font = NSFont.systemFont(ofSize: 9)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.widthAnchor.constraint(equalToConstant: 360).isActive = true

        formGrid = NSGridView(views: [
            [rowLabel("Type"), typePopup],
            [rowLabel("Describe it"), promptField],
            [sizeLabel, sizePopup],
            [NSGridCell.emptyContentView, pixelArtCheckbox],
            [durationLabel, durationField],
            [rowLabel("File name"), nameField],
        ])
        formGrid.rowSpacing = 6
        formGrid.columnSpacing = 8

        let generateRow = NSStackView(views: [generateButton, spinner, statusLabel])
        generateRow.orientation = .horizontal
        generateRow.spacing = 8

        let leftStack = NSStackView(views: [modeControl, formGrid, generateRow, hintLabel])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 10
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Right: result preview + actions ---

        let resultHeader = NSTextField(labelWithString: "RESULT")
        resultHeader.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        resultHeader.textColor = .tertiaryLabelColor

        previewImage = NSImageView()
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.wantsLayer = true
        previewImage.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        previewImage.layer?.cornerRadius = 6
        previewImage.widthAnchor.constraint(equalToConstant: 150).isActive = true
        previewImage.heightAnchor.constraint(equalToConstant: 150).isActive = true

        playButton = NSButton(title: "▶ Play", target: self, action: #selector(playClicked))
        playButton.bezelStyle = .rounded
        playButton.controlSize = .small
        playButton.isEnabled = false

        assignButton = NSButton(title: "Assign to Selection", target: self,
                                action: #selector(assignClicked))
        assignButton.bezelStyle = .rounded
        assignButton.controlSize = .small
        assignButton.isEnabled = false

        let rightStack = NSStackView(views: [resultHeader, previewImage, playButton, assignButton])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 8
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(leftStack)
        view.addSubview(rightStack)

        NSLayoutConstraint.activate([
            leftStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            leftStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            leftStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),

            rightStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            rightStack.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 28),
            rightStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        modeChanged()
    }

    // MARK: - Mode / type switching

    @objc private func modeChanged() {
        let image = isImageMode

        typePopup.removeAllItems()
        typePopup.addItems(withTitles: (image ? imageTypes : soundTypes).map { $0.title })

        // Rows: 0 type, 1 prompt, 2 size, 3 pixel art, 4 duration, 5 name.
        formGrid.row(at: 2).isHidden = !image
        formGrid.row(at: 3).isHidden = !image
        formGrid.row(at: 4).isHidden = image
        previewImage.isHidden = !image
        playButton.isHidden = image

        nameField.placeholderString = image ? "lava_tile.png (blank = auto)"
                                            : "jump.mp3 (blank = auto)"
        hintLabel.stringValue = image
            ? "Images generate at 1024 px+ via DALL·E (OpenAI key). They're always opaque — plain flat backgrounds are the easiest to clean up. Files save into Assets/ and appear in the Asset Library."
            : "Sounds generate via ElevenLabs (key in ✦ AI Settings), 0.5–22 seconds. Files save into Assets/ — double-click one in the Asset Library to assign it to an Audio node."

        lastGeneratedFile = nil
        assignButton.isEnabled = false
        playButton.isEnabled = false
        previewImage.image = nil
        statusLabel.stringValue = ""
    }

    @objc private func typeChanged() {
        // Nothing to rebuild — the type only changes prompt scaffolding.
    }

    // MARK: - Generation

    @objc private func generateClicked() {
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            statusLabel.stringValue = "Describe the asset first."
            return
        }
        guard let generator else {
            statusLabel.stringValue = "Generator not ready yet."
            return
        }
        let settings = settingsProvider?() ?? AISettings.load()

        if isImageMode {
            generateImage(prompt: prompt, generator: generator, settings: settings)
        } else {
            generateSound(prompt: prompt, generator: generator, settings: settings)
        }
    }

    private func generateImage(prompt: String, generator: AssetGenerator, settings: AISettings) {
        guard !settings.openAIKey.isEmpty else {
            statusLabel.stringValue = "Add your OpenAI key in ✦ AI Settings (images use DALL·E)."
            return
        }

        var fullPrompt = prompt + imageTypes[max(typePopup.indexOfSelectedItem, 0)].suffix
        if pixelArtCheckbox.state == .on {
            fullPrompt += ", pixel art style, crisp pixels"
        }
        let sizes = ["1024x1024", "1792x1024", "1024x1792"]
        let size = sizes[max(sizePopup.indexOfSelectedItem, 0)]
        let fileName = uniqueFileName(sanitizedFileName(ext: "png"))

        setBusy(true, message: "Generating image…")
        onLog?("✦ Generating image \"\(fileName)\": \(prompt)")

        Task { [weak self] in
            var savedName: String?
            var failure: String?
            do {
                let result = try await generator.generateImage(
                    prompt: fullPrompt, apiKey: settings.openAIKey,
                    size: size, fileName: fileName)
                savedName = result?.fileName
                if result == nil { failure = "The image API refused the request (see the log)." }
            } catch {
                failure = error.localizedDescription
            }
            self?.finishImage(savedName: savedName, failure: failure)
        }
    }

    private func finishImage(savedName: String?, failure: String?) {
        setBusy(false, message: "")
        guard let savedName else {
            statusLabel.stringValue = failure ?? "Generation failed."
            onLog?("Image generation failed: \(failure ?? "unknown error")")
            return
        }

        lastGeneratedFile = savedName
        if let assetsDir = ProjectManager.shared.assetsURL {
            previewImage.image = NSImage(contentsOf: assetsDir.appendingPathComponent(savedName))
        }
        assignButton.isEnabled = true
        statusLabel.stringValue = "Saved to Assets as \(savedName)."
        onLog?("✦ Image saved: \(savedName) — it's in the Asset Library.")
        onAssetsChanged?()
    }

    private func generateSound(prompt: String, generator: AssetGenerator, settings: AISettings) {
        guard !settings.elevenLabsKey.isEmpty else {
            statusLabel.stringValue = "Add your ElevenLabs key in ✦ AI Settings (sounds)."
            return
        }

        let fullPrompt = prompt + soundTypes[max(typePopup.indexOfSelectedItem, 0)].suffix
        let duration = Double(durationField.stringValue) ?? 2.0
        let fileName = uniqueFileName(sanitizedFileName(ext: "mp3"))

        setBusy(true, message: "Generating sound…")
        onLog?("✦ Generating sound \"\(fileName)\": \(prompt)")

        Task { [weak self] in
            var savedName: String?
            var failure: String?
            do {
                let url = try await generator.generateSound(
                    prompt: fullPrompt, apiKey: settings.elevenLabsKey,
                    duration: duration, fileName: fileName)
                savedName = url?.lastPathComponent
                if url == nil { failure = "The sound API refused the request (see the log)." }
            } catch {
                failure = error.localizedDescription
            }
            self?.finishSound(savedName: savedName, failure: failure)
        }
    }

    private func finishSound(savedName: String?, failure: String?) {
        setBusy(false, message: "")
        guard let savedName else {
            statusLabel.stringValue = failure ?? "Generation failed."
            onLog?("Sound generation failed: \(failure ?? "unknown error")")
            return
        }

        lastGeneratedFile = savedName
        playButton.isEnabled = true
        assignButton.isEnabled = true
        statusLabel.stringValue = "Saved to Assets as \(savedName)."
        onLog?("✦ Sound saved: \(savedName) — it's in the Asset Library.")
        onAssetsChanged?()
        playClicked()   // audible feedback right away
    }

    private func setBusy(_ busy: Bool, message: String) {
        generateButton.isEnabled = !busy
        statusLabel.stringValue = message
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    // MARK: - Result actions

    @objc private func playClicked() {
        guard let file = lastGeneratedFile,
              let assetsDir = ProjectManager.shared.assetsURL else { return }
        audioManager?.playSound(from: assetsDir.appendingPathComponent(file))
    }

    @objc private func assignClicked() {
        guard let file = lastGeneratedFile,
              let assetsDir = ProjectManager.shared.assetsURL else { return }
        if isImageMode {
            onAssignTexture?(assetsDir.appendingPathComponent(file))
        } else {
            onAssignAudio?(file)
        }
    }

    // MARK: - File naming

    /// Builds a safe Assets/ file name from the name field (or the
    /// prompt when the field is blank).
    private func sanitizedFileName(ext: String) -> String {
        var base = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if base.isEmpty {
            base = promptField.stringValue.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .prefix(3)
                .joined(separator: "_")
        }
        base = (base as NSString).deletingPathExtension
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        base = base.components(separatedBy: allowed.inverted).joined(separator: "_")
        if base.isEmpty { base = "generated" }
        return "\(base).\(ext)"
    }

    /// Never overwrite an existing asset — append _2, _3, … instead.
    private func uniqueFileName(_ name: String) -> String {
        guard let assetsDir = ProjectManager.shared.assetsURL else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(atPath: assetsDir.appendingPathComponent(candidate).path) {
            candidate = "\(base)_\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }
}
