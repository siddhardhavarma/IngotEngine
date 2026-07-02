//
//  ChatPanelViewController.swift
//  IngotEngine
//
//  AI chat panel with styled history and prompt field.
//

import Cocoa

class ChatPanelViewController: NSViewController, NSTextFieldDelegate {

    private var historyTextView: NSTextView!
    private var promptField: NSTextField!

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
        historyTextView.backgroundColor = NSColor(white: 0.1, alpha: 1)
        historyTextView.insertionPointColor = .white
        historyTextView.isVerticallyResizable = true
        historyTextView.isHorizontallyResizable = false
        historyTextView.autoresizingMask = [.width]
        historyTextView.textContainer?.widthTracksTextView = true
        historyTextView.textContainerInset = NSSize(width: 8, height: 6)

        scrollView.documentView = historyTextView
        view.addSubview(scrollView)

        // --- Prompt field ---
        promptField = NSTextField()
        promptField.placeholderString = "Ask the AI copilot…"
        promptField.font = NSFont.systemFont(ofSize: 12)
        promptField.delegate = self
        promptField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(promptField)

        NSLayoutConstraint.activate([
            promptField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            promptField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            promptField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            promptField.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: promptField.topAnchor, constant: -6),
        ])

        appendToHistory("Ingot AI Copilot ready.\n")
    }

    func appendToHistory(_ text: String) {
        guard let storage = historyTextView?.textStorage else { return }

        // Color user prompts vs system messages.
        let color: NSColor
        if text.hasPrefix(">") {
            color = NSColor.systemCyan
        } else if text.hasPrefix("AI:") || text.hasPrefix("AI Error") {
            color = NSColor.systemYellow
        } else if text.hasPrefix("▶") || text.hasPrefix("■") {
            color = NSColor.systemGreen
        } else {
            color = NSColor(white: 0.75, alpha: 1)
        }

        let attributed = NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color,
            ]
        )
        storage.append(attributed)
        historyTextView.scrollToEndOfDocument(nil)
    }

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
