//
//  ChatPanelViewController.swift
//  IngotEngine
//
//  AI chat panel with styled history, busy indicator, and prompt field.
//
//  Message styling is role-based (user prompt, AI status, command log,
//  error) with adaptive colors that read correctly in light and dark
//  mode. While a request is in flight the prompt field is disabled and
//  a spinner runs, so the panel never looks silently frozen.
//

import Cocoa

class ChatPanelViewController: NSViewController, NSTextFieldDelegate {

    private var historyTextView: NSTextView!
    private var promptField: NSTextField!
    private var spinner: NSProgressIndicator!

    var onPromptSubmitted: ((String) -> Void)?

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // --- Chat history ---
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        historyTextView = NSTextView()
        historyTextView.isEditable = false
        historyTextView.isSelectable = true
        historyTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        historyTextView.textColor = .labelColor
        historyTextView.backgroundColor = .textBackgroundColor
        historyTextView.isVerticallyResizable = true
        historyTextView.isHorizontallyResizable = false
        historyTextView.autoresizingMask = [.width]
        historyTextView.textContainer?.widthTracksTextView = true
        historyTextView.textContainerInset = NSSize(width: 10, height: 8)

        scrollView.documentView = historyTextView
        view.addSubview(scrollView)

        // --- Prompt row: field + spinner ---
        promptField = NSTextField()
        promptField.placeholderString = "Ask the AI copilot — e.g. \"add a coin the player can collect\"…"
        promptField.font = NSFont.systemFont(ofSize: 12)
        promptField.delegate = self
        promptField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(promptField)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            promptField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            promptField.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -6),
            promptField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            promptField.heightAnchor.constraint(equalToConstant: 24),

            spinner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: promptField.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: promptField.topAnchor, constant: -6),
        ])

        appendToHistory("Ingot AI Copilot ready. Configure a provider via ✦ AI Settings in the toolbar.")
    }

    // MARK: - Busy state

    /// Disables the prompt and spins while a request is in flight.
    func setBusy(_ busy: Bool) {
        guard isViewLoaded else { return }
        promptField.isEnabled = !busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            view.window?.makeFirstResponder(promptField)
        }
    }

    // MARK: - History rendering

    func appendToHistory(_ text: String) {
        guard let storage = historyTextView?.textStorage else { return }

        // Role-based styling, adaptive for light/dark mode.
        let color: NSColor
        var weight: NSFont.Weight = .regular
        if text.hasPrefix(">") {
            color = .controlAccentColor
            weight = .semibold
        } else if text.contains("Error") || text.hasPrefix("⚠") || text.contains("failed") {
            color = .systemRed
        } else if text.hasPrefix("AI:") {
            color = .systemPurple
        } else if text.hasPrefix("▶") || text.hasPrefix("■") {
            color = .systemGreen
        } else {
            color = .secondaryLabelColor
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = text.hasPrefix(">") ? 2 : 3
        paragraph.paragraphSpacingBefore = text.hasPrefix(">") ? 8 : 0
        paragraph.lineBreakMode = .byWordWrapping

        let attributed = NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
        storage.append(attributed)
        historyTextView.scrollToEndOfDocument(nil)
    }

    // MARK: - Prompt submission

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let prompt = promptField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !prompt.isEmpty else { return true }
            promptField.stringValue = ""
            onPromptSubmitted?(prompt)
            return true
        }
        return false
    }
}
