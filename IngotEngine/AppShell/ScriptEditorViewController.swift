//
//  ScriptEditorViewController.swift
//  IngotEngine
//
//  §5.5 — The built-in code editor.
//
//  Scripts no longer require an external editor: this bottom-panel tab
//  edits the project's .js lifecycle files in place with:
//
//    - JavaScript syntax highlighting (keywords, strings, comments,
//      numbers) and a line-number ruler
//    - Save with LIVE RELOAD: every ScriptBehavior in the scene that
//      uses the file recompiles immediately — even during Play mode
//    - An AI assist bar: describe what the script should do and the
//      LLM rewrites the file, grounded in the full engine scripting
//      reference (Node API, Input API, lifecycle) plus the current
//      scene's node list, so generated code only calls real APIs
//

import Cocoa

class ScriptEditorViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {

    // --- Injected by the editor shell ---
    var sceneProvider: (() -> Scene?)?
    var aiBridge: AIEngineBridge?
    var settingsProvider: (() -> AISettings)?

    // --- UI ---
    private var scriptPicker: NSPopUpButton!
    private var saveButton: NSButton!
    private var statusLabel: NSTextField!
    private var codeView: NSTextView!
    private var lineNumberRuler: LineNumberRulerView!
    private var aiPromptField: NSTextField!
    private var aiButton: NSButton!

    private var currentScriptName: String?
    private var hasUnsavedChanges = false {
        didSet { updateStatus() }
    }

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // --- Top bar: script picker + actions ---
        scriptPicker = NSPopUpButton()
        scriptPicker.controlSize = .small
        scriptPicker.target = self
        scriptPicker.action = #selector(scriptSelected)

        let newButton = NSButton(title: "New…", target: self, action: #selector(newScriptClicked))
        newButton.bezelStyle = .rounded
        newButton.controlSize = .small

        saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topBar = NSStackView(views: [scriptPicker, newButton, saveButton, topSpacer, statusLabel])
        topBar.orientation = .horizontal
        topBar.spacing = 6
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // --- Code view with line numbers ---
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        codeView = NSTextView()
        codeView.isEditable = true
        codeView.isRichText = false
        codeView.allowsUndo = true
        codeView.font = JSSyntaxHighlighter.font
        codeView.backgroundColor = NSColor(white: 0.09, alpha: 1)
        codeView.textColor = JSSyntaxHighlighter.baseColor
        codeView.insertionPointColor = .white
        codeView.isAutomaticQuoteSubstitutionEnabled = false
        codeView.isAutomaticDashSubstitutionEnabled = false
        codeView.isAutomaticTextReplacementEnabled = false
        codeView.isAutomaticSpellingCorrectionEnabled = false
        codeView.isVerticallyResizable = true
        codeView.isHorizontallyResizable = false
        codeView.autoresizingMask = [.width]
        codeView.textContainer?.widthTracksTextView = true
        codeView.textContainerInset = NSSize(width: 6, height: 6)
        codeView.delegate = self

        scrollView.documentView = codeView

        lineNumberRuler = LineNumberRulerView(textView: codeView)
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // --- AI assist bar ---
        aiPromptField = NSTextField()
        aiPromptField.placeholderString = "Describe what this script should do — the AI rewrites it…"
        aiPromptField.font = NSFont.systemFont(ofSize: 12)
        aiPromptField.delegate = self

        aiButton = NSButton(title: "✦ AI Edit", target: self, action: #selector(aiEditClicked))
        aiButton.bezelStyle = .rounded
        aiButton.controlSize = .small

        let aiBar = NSStackView(views: [aiPromptField, aiButton])
        aiBar.orientation = .horizontal
        aiBar.spacing = 6
        aiBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topBar)
        view.addSubview(scrollView)
        view.addSubview(aiBar)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: aiBar.topAnchor, constant: -6),

            aiPromptField.heightAnchor.constraint(equalToConstant: 22),
            aiBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            aiBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            aiBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])

        refreshScriptList()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshScriptList()
    }

    // MARK: - Script file management

    /// Reloads the picker from the project's Scripts/ folder,
    /// preserving the current selection where possible.
    func refreshScriptList() {
        guard isViewLoaded else { return }

        let scripts = ProjectManager.shared.listScripts()
        scriptPicker.removeAllItems()

        if scripts.isEmpty {
            scriptPicker.addItem(withTitle: "No scripts")
            scriptPicker.isEnabled = false
            currentScriptName = nil
            setEditorText("// Create a script with New… or assign one in the Inspector.")
            codeView.isEditable = false
            return
        }

        scriptPicker.isEnabled = true
        codeView.isEditable = true
        scriptPicker.addItems(withTitles: scripts)

        if let current = currentScriptName, scripts.contains(current) {
            scriptPicker.selectItem(withTitle: current)
        } else {
            scriptPicker.selectItem(at: 0)
            loadSelectedScript()
        }
    }

    /// Opens a specific script in the editor (e.g. from the Inspector).
    func openScript(named name: String) {
        refreshScriptList()
        guard scriptPicker.itemTitles.contains(name) else { return }
        scriptPicker.selectItem(withTitle: name)
        loadSelectedScript()
    }

    @objc private func scriptSelected() {
        loadSelectedScript()
    }

    private func loadSelectedScript() {
        guard let name = scriptPicker.titleOfSelectedItem,
              name != "No scripts",
              let scriptsDir = ProjectManager.shared.scriptsURL else { return }

        // Re-selecting the open script must not clobber unsaved edits.
        if name == currentScriptName && hasUnsavedChanges { return }

        // Autosave philosophy: switching scripts saves the one you're
        // leaving instead of silently discarding its edits.
        if hasUnsavedChanges, currentScriptName != nil, name != currentScriptName {
            saveCurrentScript()
        }

        let fileURL = scriptsDir.appendingPathComponent(name)
        let code = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

        currentScriptName = name
        setEditorText(code)
        hasUnsavedChanges = false
    }

    @objc private func newScriptClicked() {
        let alert = NSAlert()
        alert.messageText = "New Script"
        alert.informativeText = "File name for the new lifecycle script:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        nameField.placeholderString = "PlayerController.js"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !name.hasSuffix(".js") { name += ".js" }

        ProjectManager.shared.createScriptFile(named: name)
        currentScriptName = name
        refreshScriptList()
        scriptPicker.selectItem(withTitle: name)
        loadSelectedScript()
    }

    @objc private func saveClicked() {
        saveCurrentScript()
    }

    /// Writes the buffer to disk, then hot-reloads every ScriptBehavior
    /// in the scene that uses this file — the change is live on the
    /// very next frame, even mid-Play.
    private func saveCurrentScript() {
        guard let name = currentScriptName,
              let scriptsDir = ProjectManager.shared.scriptsURL else { return }

        let fileURL = scriptsDir.appendingPathComponent(name)
        do {
            try codeView.string.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
            return
        }

        var reloaded = 0
        if let scene = sceneProvider?() {
            for node in [scene.rootNode] + scene.rootNode.allDescendants() {
                for behavior in node.behaviors {
                    guard let script = behavior as? ScriptBehavior else { continue }
                    let attached = script.scriptName.hasSuffix(".js")
                        ? script.scriptName : script.scriptName + ".js"
                    if attached == name {
                        script.reload()
                        reloaded += 1
                    }
                }
            }
        }

        hasUnsavedChanges = false
        statusLabel.stringValue = reloaded > 0
            ? "Saved — reloaded on \(reloaded) node\(reloaded == 1 ? "" : "s")"
            : "Saved"
    }

    // MARK: - AI assist

    @objc private func aiEditClicked() {
        runAIEdit()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if control === aiPromptField,
           commandSelector == #selector(NSResponder.insertNewline(_:)) {
            runAIEdit()
            return true
        }
        return false
    }

    private func runAIEdit() {
        let request = aiPromptField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !request.isEmpty else { return }
        guard let bridge = aiBridge, let settings = settingsProvider?() else { return }
        guard settings.isConfigured, settings.provider != .local else {
            statusLabel.stringValue = "Configure an AI provider in AI Settings first."
            return
        }

        aiButton.isEnabled = false
        statusLabel.stringValue = "✦ \(settings.activeModel) is writing…"
        let existingCode = codeView.string
        let scene = sceneProvider?()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.aiButton.isEnabled = true }
            do {
                let code = try await bridge.generateScript(request: request,
                                                           existingCode: existingCode,
                                                           scene: scene,
                                                           settings: settings)
                guard !code.isEmpty else {
                    self.statusLabel.stringValue = "AI returned no code."
                    return
                }
                self.setEditorText(code)
                self.hasUnsavedChanges = true
                self.aiPromptField.stringValue = ""
                self.statusLabel.stringValue = "✦ Rewritten — review and Save to apply."
            } catch {
                self.statusLabel.stringValue = "AI error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Text handling

    private func setEditorText(_ text: String) {
        codeView.string = text
        JSSyntaxHighlighter.highlight(codeView.textStorage)
        lineNumberRuler.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        hasUnsavedChanges = true
        JSSyntaxHighlighter.highlight(codeView.textStorage)
        lineNumberRuler.needsDisplay = true
    }

    private func updateStatus() {
        guard isViewLoaded else { return }
        if hasUnsavedChanges {
            statusLabel.stringValue = "● unsaved changes"
        }
    }
}

// ---------------------------------------------------------------------------
// JSSyntaxHighlighter — regex-based JavaScript highlighting
// ---------------------------------------------------------------------------
enum JSSyntaxHighlighter {

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let baseColor = NSColor(white: 0.88, alpha: 1)

    private static let keywordColor = NSColor.systemPink
    private static let stringColor = NSColor.systemOrange
    private static let numberColor = NSColor.systemPurple
    private static let commentColor = NSColor.systemGreen

    private static let keywordPattern =
        "\\b(var|let|const|function|if|else|for|while|do|return|true|false|null|undefined|new|this|typeof|break|continue|switch|case|default|in|of)\\b"

    /// (pattern, color, options) — applied in order; later wins.
    private static let rules: [(NSRegularExpression, NSColor)] = {
        func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // Patterns are compile-time constants — a failure is a
            // programmer error, so crash loudly in development.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            (regex(keywordPattern), keywordColor),
            (regex("\\b\\d+(?:\\.\\d+)?\\b"), numberColor),
            (regex("\"[^\"\\n]*\"|'[^'\\n]*'"), stringColor),
            (regex("//[^\\n]*"), commentColor),
            (regex("/\\*.*?\\*/", [.dotMatchesLineSeparators]), commentColor),
        ]
    }()

    /// Re-applies highlighting over the whole storage. Lifecycle
    /// scripts are small (tens of lines), so full passes are cheap.
    static func highlight(_ storage: NSTextStorage?) {
        guard let storage = storage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: baseColor], range: fullRange)
        for (regex, color) in rules {
            regex.enumerateMatches(in: storage.string, range: fullRange) { match, _, _ in
                if let range = match?.range {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }
        storage.endEditing()
    }
}

// ---------------------------------------------------------------------------
// LineNumberRulerView — line numbers for the code view
// ---------------------------------------------------------------------------
final class LineNumberRulerView: NSRulerView {

    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36

        // Redraw when the text scrolls or changes.
        if let contentView = textView.enclosingScrollView?.contentView {
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,
                selector: #selector(redraw),
                name: NSView.boundsDidChangeNotification,
                object: contentView)
        }
        NotificationCenter.default.addObserver(self,
            selector: #selector(redraw),
            name: NSText.didChangeNotification,
            object: textView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ]

        let text = textView.string as NSString
        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)

        // Count the line number at the top of the visible range.
        var lineNumber = 1
        var index = 0
        while index < charRange.location {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            lineNumber += 1
        }

        // Draw a number beside each visible line's first fragment.
        var lineStart = index
        while lineStart <= NSMaxRange(charRange) && lineStart <= text.length {
            let lineRect: NSRect
            if lineStart < text.length {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                          effectiveRange: nil)
            } else {
                // Trailing empty line after a final newline.
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.height == 0 { break }
            }

            let yInTextView = lineRect.minY + textView.textContainerInset.height
            let y = convert(NSPoint(x: 0, y: yInTextView), from: textView).y

            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + 1),
                       withAttributes: attributes)

            if lineStart >= text.length { break }
            lineStart = NSMaxRange(text.lineRange(for: NSRange(location: lineStart, length: 0)))
            lineNumber += 1
        }
    }
}
