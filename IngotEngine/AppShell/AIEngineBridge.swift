//
//  AIEngineBridge.swift
//  IngotEngine
//
//  The bridge between AI/LLM providers and the engine's scene graph.
//
//  Supports multiple LLM providers (OpenAI, Claude, Gemini, Local) and
//  dispatches asset generation to the AssetDownloadQueue so network
//  requests never block the main render loop.
//

import Foundation

// ---------------------------------------------------------------------------
// AICommand — a single instruction from the LLM
// ---------------------------------------------------------------------------
struct AICommand: Codable {
    let action: String
    let targetName: String?
    let property: String?
    let value: Float?
    let prompt: String?
    let code: String?        // Used by "attachScript" action.
}

// ---------------------------------------------------------------------------
// AIEngineBridge
// ---------------------------------------------------------------------------
class AIEngineBridge {

    /// The background download queue for asset generation.
    var downloadQueue: AssetDownloadQueue?

    // MARK: - Prompt Building

    func buildPrompt(userText: String, currentScene: Scene) -> String {
        let sceneJSON = SceneSerializer.serialize(currentScene)

        return """
        [System Prompt]
        You are an AI game engine copilot for Ingot Engine.
        The current scene state is:
        \(sceneJSON)

        You must respond ONLY with a JSON array of commands. Each command is an object.

        Supported actions:
        1. "updateProperty" — modify a node's transform.
           Required: "targetName", "property" (positionX|positionY|rotation|scaleX|scaleY), "value" (Float)

        2. "generateTexture" — generate an image and apply it to a sprite.
           Required: "targetName" (must be a SpriteNode), "prompt" (image description)

        3. "generateSound" — generate a sound effect and play it.
           Required: "prompt" (sound description)

        4. "attachScript" — create a lifecycle JavaScript file and attach it to a node.
           Required: "targetName", "code" (JavaScript string using lifecycle format)
           The code MUST use this lifecycle pattern:
           var Script = { start: function(node) {}, update: function(node, dt, time) {} };
           Available in update: node.x, node.y, node.name, node.setFrame(), dt, time, Input.isActionPressed("action_name")

        5. "addRule" — add a visual-scripting rule to a node's event sheet.
           Required: "targetName", "event" (object), "actions" (array of objects)
           Event types: {"type":"onActionHeld","action":"move_left"}, {"type":"everyFrame"}, {"type":"onStart"}, {"type":"onCollision"}, {"type":"onSignal","signal":"name"}
           Action types: {"type":"move","x":100,"y":0}, {"type":"rotate","degreesPerSecond":45}, {"type":"emitSignal","name":"sig"}, {"type":"playSound","fileName":"bump.wav"}, {"type":"setProperty","property":"scaleX","value":2}, {"type":"destroy"}

        Example response:
        [
          {"action": "updateProperty", "targetName": "Player", "property": "positionX", "value": 300.0},
          {"action": "addRule", "targetName": "Player", "event": {"type": "onCollision"}, "actions": [{"type": "emitSignal", "name": "PlayerHit"}]},
          {"action": "attachScript", "targetName": "Player", "code": "var Script = { start: function(node) {}, update: function(node, dt, time) { node.x += 100 * dt; } };"}
        ]

        Do not include any text outside the JSON array. No markdown, no explanation.

        [User Prompt]
        \(userText)
        """
    }

    // MARK: - LLM Communication

    /// Sends the prompt to the configured LLM provider, cleans the
    /// response of any markdown/boilerplate, and returns raw JSON.
    func sendPromptToLLM(prompt: String, settings: AISettings) async throws -> String {
        let rawResponse: String

        switch settings.provider {
        case .local:
            rawResponse = "[]"
        case .openAI:
            rawResponse = try await sendToOpenAI(prompt: prompt, apiKey: settings.openAIKey)
        case .claude:
            rawResponse = try await sendToClaude(prompt: prompt, apiKey: settings.claudeKey)
        case .gemini:
            rawResponse = try await sendToGemini(prompt: prompt, apiKey: settings.geminiKey)
        }

        // Strip markdown fences and boilerplate before returning.
        return stripToJSON(rawResponse)
    }

    // MARK: - JSON Stripping

    /// Extracts a clean JSON array from an LLM response that may contain
    /// markdown code fences, conversational prose, or other wrapping.
    ///
    /// LLMs frequently wrap JSON in markdown even when told not to:
    ///
    ///   Here are the commands:
    ///   ```json
    ///   [{"action": "updateProperty", ...}]
    ///   ```
    ///   Let me know if you need anything else!
    ///
    /// This function finds the first '[' and last ']' and extracts
    /// everything between them (inclusive), discarding all surrounding text.
    private func stripToJSON(_ text: String) -> String {
        // Fast path: already clean JSON.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return trimmed
        }

        // Find the outermost [ ... ] bounds.
        guard let openIndex = trimmed.firstIndex(of: "["),
              let closeIndex = trimmed.lastIndex(of: "]") else {
            // No array found at all — return empty array so the decoder
            // doesn't crash and the engine logs a clean "0 commands" message.
            print("AIEngineBridge: No JSON array found in response. Returning [].")
            return "[]"
        }

        // Ensure the close bracket comes after the open bracket.
        guard closeIndex >= openIndex else {
            return "[]"
        }

        return String(trimmed[openIndex...closeIndex])
    }

    // MARK: - Provider Implementations

    /// OpenAI Chat Completions API (GPT-4o).
    /// Temperature 0.0 for maximum structural consistency.
    private func sendToOpenAI(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": "Respond ONLY with a JSON array of commands. No markdown, no prose."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return "[]"
        }
        return content
    }

    /// Anthropic Claude Messages API.
    /// Temperature 0.0 for maximum structural consistency.
    private func sendToClaude(prompt: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "temperature": 0.0,
            "system": "Respond ONLY with a JSON array of commands. No markdown, no prose.",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let text = contentArray.first?["text"] as? String else {
            return "[]"
        }
        return text
    }

    /// Google Gemini GenerateContent API.
    /// Temperature 0.0 for maximum structural consistency.
    private func sendToGemini(prompt: String, apiKey: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)"
        let url = URL(string: urlString)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.0
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            return "[]"
        }
        return text
    }

    // MARK: - Command Execution

    func executeCommands(jsonString: String,
                         in scene: Scene,
                         settings: AISettings,
                         onLog: @escaping @MainActor (String) -> Void) {

        guard let data = jsonString.data(using: .utf8) else {
            onLog("Error: Could not encode JSON string to data.")
            return
        }

        let commands: [AICommand]
        do {
            commands = try JSONDecoder().decode([AICommand].self, from: data)
        } catch {
            onLog("Error: Could not decode AI commands: \(error.localizedDescription)")
            return
        }

        for command in commands {
            switch command.action {
            case "updateProperty":
                executeUpdateProperty(command, in: scene, onLog: onLog)
            case "generateTexture":
                dispatchGenerateTexture(command, in: scene, settings: settings, onLog: onLog)
            case "generateSound":
                dispatchGenerateSound(command, settings: settings, onLog: onLog)
            case "attachScript":
                executeAttachScript(command, in: scene, onLog: onLog)
            case "addRule":
                executeAddRule(rawJSON: jsonString, commandIndex: commands.firstIndex(where: { $0.action == "addRule" && $0.targetName == command.targetName }) ?? 0, in: scene, onLog: onLog)
            default:
                onLog("Warning: Unknown action \"\(command.action)\".")
            }
        }
    }

    // MARK: - Synchronous Command Handlers

    private func executeUpdateProperty(_ command: AICommand,
                                       in scene: Scene,
                                       onLog: @escaping (String) -> Void) {
        guard let targetName = command.targetName,
              let property = command.property,
              let value = command.value else {
            onLog("Error: updateProperty requires targetName, property, and value.")
            return
        }

        guard let node = findNode(named: targetName, in: scene.rootNode) else {
            onLog("Warning: Node \"\(targetName)\" not found.")
            return
        }

        switch property {
        case "positionX": node.position.x = value
        case "positionY": node.position.y = value
        case "rotation":  node.rotation = value
        case "scaleX":    node.scale.x = value
        case "scaleY":    node.scale.y = value
        default:
            onLog("Warning: Unknown property \"\(property)\".")
            return
        }

        onLog("Set \"\(node.name)\".\(property) = \(value)")
    }

    private func executeAttachScript(_ command: AICommand,
                                      in scene: Scene,
                                      onLog: @escaping (String) -> Void) {
        guard let targetName = command.targetName,
              let code = command.code else {
            onLog("Error: attachScript requires targetName and code.")
            return
        }

        guard let node = findNode(named: targetName, in: scene.rootNode) else {
            onLog("Warning: Node \"\(targetName)\" not found.")
            return
        }

        // Generate a script filename from the node name.
        let scriptName = "\(targetName)_AI_Script.js"

        // Write the code to a .js file in the project's Scripts/ folder.
        guard let scriptsDir = ProjectManager.shared.scriptsURL else {
            onLog("Warning: No project open, cannot write script file.")
            return
        }

        let fileURL = scriptsDir.appendingPathComponent(scriptName)
        do {
            try code.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            onLog("Error writing script file: \(error.localizedDescription)")
            return
        }

        // Remove any existing ScriptBehavior and assign the new file.
        node.removeBehaviors { $0 is ScriptBehavior }

        let script = ScriptBehavior(scriptName: scriptName)
        node.addBehavior(script)
        onLog("Created \(scriptName) and attached to \"\(node.name)\".")
    }

    /// Parses an "addRule" command from the raw JSON (since Codable can't
    /// handle the nested event/actions dictionaries) and adds it to the
    /// target node's behavior.
    private func executeAddRule(rawJSON: String,
                                commandIndex: Int,
                                in scene: Scene,
                                onLog: @escaping (String) -> Void) {
        // Re-parse the raw JSON to get the untyped dictionaries.
        guard let data = rawJSON.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            onLog("Error: Could not re-parse JSON for addRule.")
            return
        }

        // Find the addRule command in the array.
        let ruleCmds = array.filter { ($0["action"] as? String) == "addRule" }
        guard commandIndex < ruleCmds.count else {
            onLog("Error: addRule command index out of bounds.")
            return
        }

        let cmdDict = ruleCmds[commandIndex]
        guard let targetName = cmdDict["targetName"] as? String else {
            onLog("Error: addRule requires targetName.")
            return
        }

        guard let node = findNode(named: targetName, in: scene.rootNode) else {
            onLog("Warning: Node \"\(targetName)\" not found.")
            return
        }

        guard let eventDict = cmdDict["event"] as? [String: Any],
              let actionDicts = cmdDict["actions"] as? [[String: Any]] else {
            onLog("Error: addRule requires event and actions.")
            return
        }

        // Use the SceneDeserializer's rule-building logic (it's already tested).
        // We need to call the private methods through a workaround — build the
        // rule dict in the format the deserializer expects.
        let ruleDict: [String: Any] = ["event": eventDict, "actions": actionDicts]
        guard let ruleData = try? JSONSerialization.data(withJSONObject: ruleDict),
              let ruleJSON = String(data: ruleData, encoding: .utf8),
              let fullJSON = "{ \"rootNode\": { \"type\": \"Node\", \"name\": \"temp\", \"positionX\": 0, \"positionY\": 0, \"scaleX\": 1, \"scaleY\": 1, \"rotation\": 0, \"enabled\": true, \"behaviors\": [{ \"type\": \"RuleBehavior\", \"rules\": [\(ruleJSON)] }], \"children\": [] } }".data(using: .utf8),
              let tempRoot = SceneDeserializer.deserialize(jsonString: String(data: fullJSON, encoding: .utf8)!),
              let tempBehavior = tempRoot.behaviors.first,
              let newRule = tempBehavior.rules.first else {
            onLog("Error: Could not build rule from AI command.")
            return
        }

        // Add the rule to the node's first non-script behavior.
        if let behavior = node.behaviors.first(where: { !($0 is ScriptBehavior) }) {
            behavior.rules.append(newRule)
        } else {
            node.addBehavior(Behavior(rules: [newRule]))
        }

        onLog("Added rule to \"\(targetName)\": \(newRule.event.displayName) → \(newRule.actions.map { $0.displayName }.joined(separator: ", "))")
    }

    // MARK: - Async Command Dispatchers

    private func dispatchGenerateTexture(_ command: AICommand,
                                         in scene: Scene,
                                         settings: AISettings,
                                         onLog: @escaping @MainActor (String) -> Void) {
        guard let targetName = command.targetName,
              let imagePrompt = command.prompt else {
            onLog("Error: generateTexture requires targetName and prompt.")
            return
        }

        guard let sprite = findNode(named: targetName, in: scene.rootNode) as? SpriteNode else {
            onLog("Warning: SpriteNode \"\(targetName)\" not found.")
            return
        }

        guard let queue = downloadQueue else {
            onLog("Warning: AssetDownloadQueue not configured.")
            return
        }

        onLog("Queued texture generation for \"\(targetName)\": \"\(imagePrompt)\"")

        queue.dispatchTextureGeneration(
            for: sprite,
            prompt: imagePrompt,
            apiKey: settings.openAIKey,
            onLog: onLog
        )
    }

    private func dispatchGenerateSound(_ command: AICommand,
                                       settings: AISettings,
                                       onLog: @escaping @MainActor (String) -> Void) {
        guard let soundPrompt = command.prompt else {
            onLog("Error: generateSound requires a prompt.")
            return
        }

        guard let queue = downloadQueue else {
            onLog("Warning: AssetDownloadQueue not configured.")
            return
        }

        onLog("Queued sound generation: \"\(soundPrompt)\"")

        queue.dispatchSoundGeneration(
            prompt: soundPrompt,
            apiKey: settings.elevenLabsKey,
            onLog: onLog
        )
    }

    // MARK: - Node Lookup

    private func findNode(named name: String, in node: Node) -> Node? {
        if node.name == name { return node }
        for child in node.children {
            if let found = findNode(named: name, in: child) {
                return found
            }
        }
        return nil
    }
}
