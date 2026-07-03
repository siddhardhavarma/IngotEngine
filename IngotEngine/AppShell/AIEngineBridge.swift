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
//  The command set covers the FULL engine feature surface — node
//  creation (sprites, shapes, text, cameras, audio, triggers, timers,
//  particles, tile maps), transforms, physics, prefabs, behaviors,
//  scripts, and asset generation — so the copilot can build a playable
//  game end-to-end from natural-language prompts.
//

import Foundation
import Metal
import simd

/// A provider-side failure (bad key, unknown model, rate limit, …)
/// with the provider's own message so users see the real cause in the
/// chat panel instead of silence.
struct AIProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// ---------------------------------------------------------------------------
// AIEngineBridge
// ---------------------------------------------------------------------------
class AIEngineBridge {

    /// The background download queue for asset generation.
    var downloadQueue: AssetDownloadQueue?

    /// Provides the default texture for AI-created sprites/tile maps
    /// (injected by the editor; nil leaves textures unassigned).
    var defaultTextureProvider: (() -> Any?)?

    // MARK: - Prompt Building

    /// Builds the full prompt. `history` carries recent exchanges
    /// ("User: …" / "Executed: …" lines) so follow-ups like "make it
    /// bigger" resolve against what was just discussed.
    func buildPrompt(userText: String, currentScene: Scene, history: [String] = []) -> String {
        let sceneJSON = SceneSerializer.serialize(currentScene)
        let prefabs = PrefabLibrary.list()
        let prefabList = prefabs.isEmpty ? "(none saved yet)" : prefabs.joined(separator: ", ")
        let scenes = ProjectManager.shared.listScenes()
        let sceneList = scenes.isEmpty ? "(none saved yet)" : scenes.joined(separator: ", ")
        let animations = AnimationLibrary.list()
        let animationList = animations.isEmpty ? "(none defined yet)" : animations.joined(separator: ", ")
        let tileSets = TileSetLibrary.list()
        let tileSetList = tileSets.isEmpty ? "(none defined yet)" : tileSets.joined(separator: ", ")

        return """
        [System Prompt]
        You are an AI game engine copilot for Ingot Engine, a 2D engine targeting iPhone/iPad/Apple TV.
        Coordinate system: +X right, +Y UP, positions in pixels. The design canvas is roughly 800x600.

        The current scene state is:
        \(sceneJSON)

        Saved prefabs: \(prefabList)
        Saved scenes: \(sceneList)
        Animation clips: \(animationList)
        Tile sets: \(tileSetList)

        You must respond ONLY with a JSON array of commands. Each command is an object with an "action" key.

        Supported actions:

        1. "createNode" — add a node to the scene.
           Required: "type" (Node|SpriteNode|ShapeNode|TextNode|CameraNode|AudioNode|CollisionNode|TimerNode|ParticleNode|TileMapNode), "name"
           Optional: "parentName" (default: scene root), "x", "y", "zIndex", "groups" (array of strings)
           Type extras — ShapeNode: "color" [r,g,b,a 0-1], "width", "height". TextNode: "text", "fontSize". AudioNode: "soundFile", "playOnStart", "loops". CollisionNode: "triggerSignal", "width", "height". TimerNode: "waitTime", "oneShot", "autostart", "signal". ParticleNode/TileMapNode: create first, then configure with the commands below.

        2. "deleteNode" — remove a node (and its children).
           Required: "targetName"

        3. "updateProperty" — set a numeric property on a node.
           Required: "targetName", "property" (positionX|positionY|rotation|scaleX|scaleY|zIndex|zoom|visible), "value" (number; visible: 1/0)

        4. "setColor" — tint a node. Sets fill color on ShapeNode, modulate tint on other sprites/text.
           Required: "targetName", "color" [r,g,b,a 0-1]

        5. "setText" — change a TextNode.
           Required: "targetName", "text". Optional: "fontSize"

        6. "addPhysicsBody" — make a node collide.
           Required: "targetName", "sizeX", "sizeY", "isDynamic" (true = moves, false = wall/floor)
           Optional: "gravityScale" (0 = top-down, 1 = platformer), "collisionLayer", "collisionMask"

        7. "setVelocity" — set a node's physics velocity in px/s. Required: "targetName", "x", "y"

        8. "setGravity" — set world gravity in px/s². Required: "x", "y" (platformer: x=0, y=-980; top-down: 0,0). Saved with the scene.

        9. "configureParticles" — set up a ParticleNode.
           Required: "targetName". Optional: "amount", "lifetime", "oneShot", "direction" (degrees, 90=up), "spread", "initialVelocity", "gravityX", "gravityY", "startScale", "endScale", "startColor" [r,g,b,a], "endColor" [r,g,b,a], "emitting"

        10. "configureTileMap" — set up a TileMapNode's atlas and collision.
            Required: "targetName". Optional: "tileSet" (name of a saved tile set — applies its atlas, grid, tile size, and solid tiles in one go; PREFER this when one exists), "tileWidth", "tileHeight", "atlasColumns", "atlasRows", "solidTiles" (array of tile indices that block movement). Explicit fields override the tile set's values.

        11. "paintTiles" — place tiles on a TileMapNode.
            Required: "targetName", and either "tiles" (array of [x, y, tileIndex] triples; tileIndex -1 erases) or a fill rect: "x", "y", "width", "height", "tileIndex"

        12. "setCameraFollow" — make a camera track a node smoothly.
            Required: "targetName" (the camera), "followTarget" (node name). Optional: "smoothing" (0 = rigid, ~5 = smooth chase)

        13. "configureTimer" — set up a TimerNode.
            Required: "targetName". Optional: "waitTime" (seconds), "oneShot", "autostart", "signal" (emitted on timeout)

        14. "savePrefab" — save a node subtree as a reusable prefab. Required: "targetName", "prefabName"

        15. "spawnPrefab" — instantiate a saved prefab. Required: "prefabName", "x", "y". Optional: "name", "parentName"

        16. "addToGroup" — tag a node with a group. Required: "targetName", "group"

        17. "addRule" — add a visual-scripting rule to a node's event sheet.
            Required: "targetName", "event" (object), "actions" (array of objects)
            Event types: {"type":"onActionHeld","action":"move_left"}, {"type":"onActionJustPressed","action":"action"}, {"type":"everyFrame"}, {"type":"onStart"}, {"type":"onCollision"}, {"type":"onSignal","signal":"name"}
            Action types: {"type":"move","x":100,"y":0}, {"type":"rotate","degreesPerSecond":45}, {"type":"emitSignal","name":"sig"}, {"type":"playSound","fileName":"bump.wav"}, {"type":"setProperty","property":"scaleX","value":2}, {"type":"setVelocity","x":0,"y":600}, {"type":"spawnPrefab","prefab":"Enemy","x":100,"y":300}, {"type":"changeScene","scene":"Level2"}, {"type":"playAnimation","animation":"walk"}, {"type":"destroy"}
            Input actions available: move_left, move_right, move_up, move_down, action (Space / touch button).
            Timers emit their "signal" on timeout — pair a TimerNode with onSignal rules for spawn waves.
            Triggers (CollisionNode) emit their "triggerSignal" when something enters them.
            Collisions also emit "Collision:<NodeName>" signals for per-node reactions.

        18. "attachScript" — create a lifecycle JavaScript file and attach it to a node.
            Required: "targetName", "code" (JavaScript string using lifecycle format)
            The code MUST use this lifecycle pattern:
            var Script = { start: function(node) {}, update: function(node, dt, time) {} };
            Node API: node.x, node.y, node.rotationDegrees, node.scaleX, node.scaleY, node.zIndexJS, node.visible, node.name, node.jsZoom (cameras), node.setFrame(cols,rows,col,row), node.getChild(name), node.emitSignal(name), node.setVelocity(x,y), node.spawn(prefabName,x,y), node.character, node.currentAnimation, node.playAnimation(clipName), node.stopAnimation(), node.destroy()
            Sprites with a character attached resolve playAnimation("run_left") within that character's clips and swap to the clip's sprite sheet automatically; playAnimation is safe to call every frame.
            Input API: Input.isActionPressed(name), Input.isActionJustPressed(name)

        19. "generateTexture" — AI-generate an image and apply it to a sprite.
            Required: "targetName" (a SpriteNode), "prompt" (image description)

        20. "generateSound" — AI-generate a sound effect and play it.
            Required: "prompt" (sound description)

        21. "defineAnimation" — create/update a named sprite-sheet animation clip.
            Required: "name", "gridWidth", "gridHeight" (sheet layout), "startFrame", "endFrame" (0-based, inclusive)
            Optional: "fps" (default 8), "loops" (default true), "character" (group clips per character, e.g. "Player"), "textureName" (the Assets/ sprite-sheet file — playing the clip swaps the sprite's texture to it)

        22. "setDefaultAnimation" — auto-play a clip on a sprite when the scene starts.
            Required: "targetName" (a SpriteNode), "animation" (clip name)

        23. "playAnimation" — play a clip on a sprite right now (during Play mode).
            Required: "targetName" (a SpriteNode), "animation" (clip name)

        24. "setCharacter" — attach an animation character to a sprite. Its clips then
            resolve by short name (playAnimation("run_left")), and "idle" auto-plays on
            scene start if the character defines it.
            Required: "targetName" (a SpriteNode), "character"

        Example response:
        [
          {"action": "createNode", "type": "ShapeNode", "name": "Ground", "x": 400, "y": 50, "color": [0.4, 0.3, 0.2, 1], "width": 800, "height": 60},
          {"action": "addPhysicsBody", "targetName": "Ground", "sizeX": 800, "sizeY": 60, "isDynamic": false},
          {"action": "setGravity", "x": 0, "y": -980},
          {"action": "addRule", "targetName": "Player", "event": {"type": "onActionJustPressed", "action": "action"}, "actions": [{"type": "setVelocity", "x": 0, "y": 600}]}
        ]

        Do not include any text outside the JSON array. No markdown, no explanation.

        \(history.isEmpty ? "" : "[Recent Conversation]\n" + history.joined(separator: "\n") + "\n")
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
            rawResponse = try await sendToOpenAI(prompt: prompt, apiKey: settings.openAIKey,
                                                 model: settings.openAIModel)
        case .claude:
            rawResponse = try await sendToClaude(prompt: prompt, apiKey: settings.claudeKey,
                                                 model: settings.claudeModel)
        case .gemini:
            rawResponse = try await sendToGemini(prompt: prompt, apiKey: settings.geminiKey,
                                                 model: settings.geminiModel)
        }

        // Strip markdown fences and boilerplate before returning.
        return stripToJSON(rawResponse)
    }

    // MARK: - Script Generation (built-in code editor)

    /// The complete engine scripting reference, given to the LLM so
    /// generated code only uses APIs that actually exist.
    static let scriptingReference = """
    Ingot Engine JavaScript scripting reference:

    Every script file defines a lifecycle object:
        var Script = {
            start: function(node) { /* once, when the scene starts */ },
            update: function(node, dt, time) { /* every frame */ }
        };
    dt = seconds since last frame, time = seconds since play started.

    Node API (available on `node` and anything getChild returns):
      node.x, node.y                — position (pixels, +Y is UP)
      node.rotationDegrees          — rotation
      node.scaleX, node.scaleY      — scale
      node.zIndexJS                 — draw order (higher = on top)
      node.visible                  — enabled/visible flag
      node.name                     — node name (read-only)
      node.jsZoom                   — camera zoom (CameraNode only)
      node.setFrame(cols, rows, col, row) — sprite-sheet frame
      node.getChild("Name")         — find a descendant by name
      node.emitSignal("Name")       — broadcast an EventBus signal
      node.setVelocity(x, y)        — set physics velocity (needs a body)
      node.spawn("Prefab", x, y)    — instantiate a saved prefab
      node.changeScene("Scene")     — switch scenes at end of frame
      node.character                — attached animation character (get/set)
      node.currentAnimation         — clip currently playing ("" = none)
      node.playAnimation("clip")    — play a clip; resolves within the
                                      attached character first, swaps the
                                      sprite sheet automatically; safe to
                                      call every frame (no-op if playing)
      node.stopAnimation()          — freeze on the current frame
      node.destroy()                — remove the node

    Typical animation-driving pattern in update():
        if (Input.isActionPressed("move_left"))       node.playAnimation("run_left");
        else if (Input.isActionPressed("move_right")) node.playAnimation("run_right");
        else                                          node.playAnimation("idle");

    Input API (global `Input`):
      Input.isActionPressed("move_left")      — held this frame
      Input.isActionJustPressed("action")     — first frame only
      Actions: move_left, move_right, move_up, move_down, action.

    Physics notes: bodies with velocity are integrated by the engine;
    world gravity applies unless gravityScale is 0. For a jump: check
    isActionJustPressed then node.setVelocity(currentX, 600).

    Scripts attach to ANY node type — including the camera. A camera
    script can pan (node.x/node.y) or zoom (node.jsZoom) for cutscenes
    and manual scrolling; if the camera has a follow target set, the
    follow runs after the script and wins on position.
    """

    /// Generates or rewrites a lifecycle script with full engine
    /// context. Returns pure JavaScript (fences stripped).
    func generateScript(request: String,
                        existingCode: String,
                        scene: Scene?,
                        settings: AISettings) async throws -> String {
        var sceneSummary = "(no scene loaded)"
        if let scene = scene {
            let names = ([scene.rootNode] + scene.rootNode.allDescendants())
                .map { "\($0.name) (\(type(of: $0)))" }
                .joined(separator: ", ")
            sceneSummary = names
        }

        let prompt = """
        You are the code assistant inside Ingot Engine's script editor.

        \(AIEngineBridge.scriptingReference)

        Nodes in the current scene: \(sceneSummary)

        Current content of the script file being edited:
        ```javascript
        \(existingCode.isEmpty ? "// (empty file)" : existingCode)
        ```

        Task: \(request)

        Respond with ONLY the complete, final JavaScript file content —
        the full `var Script = {...};` definition. No markdown fences,
        no explanation, no comments about what changed.
        """

        let raw: String
        switch settings.provider {
        case .local:
            raw = existingCode
        case .openAI:
            raw = try await sendToOpenAI(prompt: prompt, apiKey: settings.openAIKey,
                                         model: settings.openAIModel)
        case .claude:
            raw = try await sendToClaude(prompt: prompt, apiKey: settings.claudeKey,
                                         model: settings.claudeModel)
        case .gemini:
            raw = try await sendToGemini(prompt: prompt, apiKey: settings.geminiKey,
                                         model: settings.geminiModel)
        }

        return AIEngineBridge.stripCodeFences(raw)
    }

    /// Removes markdown code fences from an LLM code response.
    static func stripCodeFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // Drop the opening fence line (``` or ```javascript).
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            // Drop the closing fence.
            if let closingRange = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<closingRange.lowerBound])
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JSON Stripping

    /// Extracts a clean JSON array from an LLM response that may contain
    /// markdown code fences, conversational prose, or other wrapping.
    ///
    /// LLMs frequently wrap JSON in markdown even when told not to.
    /// This function finds the first '[' and last ']' and extracts
    /// everything between them (inclusive), discarding surrounding text.
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

    /// Sends a request and validates the HTTP status. Non-2xx responses
    /// throw with the provider's error message extracted from the body
    /// (all three providers use an "error" envelope), so failures like
    /// invalid keys or unknown model IDs surface in the chat panel.
    private func post(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIProviderError(message: "Network error: \(error.localizedDescription)")
        }

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            var message = "HTTP \(http.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? [String: Any],
                   let detail = error["message"] as? String {
                    message += ": \(detail)"
                } else if let detail = json["message"] as? String {
                    message += ": \(detail)"
                }
            }
            throw AIProviderError(message: message)
        }

        return data
    }

    /// Thrown when a 2xx response doesn't have the expected shape.
    private func unexpectedFormat(_ data: Data) -> AIProviderError {
        let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
        return AIProviderError(message: "Unexpected response format: \(snippet)")
    }

    /// OpenAI Chat Completions API.
    /// Temperature 0.0 for maximum structural consistency.
    private func sendToOpenAI(prompt: String, apiKey: String, model: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "Respond ONLY with a JSON array of commands. No markdown, no prose."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await post(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw unexpectedFormat(data)
        }
        return content
    }

    /// Anthropic Claude Messages API.
    private func sendToClaude(prompt: String, apiKey: String, model: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": "Respond ONLY with a JSON array of commands. No markdown, no prose.",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await post(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let textBlock = contentArray.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String else {
            throw unexpectedFormat(data)
        }
        return text
    }

    /// Google Gemini GenerateContent API.
    /// Temperature 0.0 for maximum structural consistency.
    private func sendToGemini(prompt: String, apiKey: String, model: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
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

        let data = try await post(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw unexpectedFormat(data)
        }
        return text
    }

    // MARK: - Command Execution

    /// Parses the LLM's JSON array and executes each command in order.
    /// Commands are untyped dictionaries — every handler validates its
    /// own fields, so one malformed command never aborts the batch.
    /// Returns a compact summary of what ran ("createNode(Coin)") for
    /// the conversation history.
    @discardableResult
    func executeCommands(jsonString: String,
                         in scene: Scene,
                         settings: AISettings,
                         onLog: @escaping @MainActor (String) -> Void) -> [String] {

        guard let data = jsonString.data(using: .utf8),
              let commands = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            onLog("Error: Could not decode AI commands as a JSON array.")
            return []
        }

        guard !commands.isEmpty else {
            onLog("The model returned no commands — try rephrasing the request.")
            return []
        }
        onLog("Running \(commands.count) command\(commands.count == 1 ? "" : "s")…")

        var executed: [String] = []
        for command in commands {
            let action = command["action"] as? String ?? ""
            let subject = (command["targetName"] as? String)
                ?? (command["name"] as? String)
                ?? (command["prefabName"] as? String)
                ?? ""
            executed.append(subject.isEmpty ? action : "\(action)(\(subject))")
            switch action {
            case "createNode":        executeCreateNode(command, in: scene, onLog: onLog)
            case "deleteNode":        executeDeleteNode(command, in: scene, onLog: onLog)
            case "updateProperty":    executeUpdateProperty(command, in: scene, onLog: onLog)
            case "setColor":          executeSetColor(command, in: scene, onLog: onLog)
            case "setText":           executeSetText(command, in: scene, onLog: onLog)
            case "addPhysicsBody":    executeAddPhysicsBody(command, in: scene, onLog: onLog)
            case "setVelocity":       executeSetVelocity(command, in: scene, onLog: onLog)
            case "setGravity":        executeSetGravity(command, in: scene, onLog: onLog)
            case "configureParticles": executeConfigureParticles(command, in: scene, onLog: onLog)
            case "configureTileMap":  executeConfigureTileMap(command, in: scene, onLog: onLog)
            case "paintTiles":        executePaintTiles(command, in: scene, onLog: onLog)
            case "setCameraFollow":   executeSetCameraFollow(command, in: scene, onLog: onLog)
            case "configureTimer":    executeConfigureTimer(command, in: scene, onLog: onLog)
            case "savePrefab":        executeSavePrefab(command, in: scene, onLog: onLog)
            case "spawnPrefab":       executeSpawnPrefab(command, in: scene, onLog: onLog)
            case "addToGroup":        executeAddToGroup(command, in: scene, onLog: onLog)
            case "addRule":           executeAddRule(command, in: scene, onLog: onLog)
            case "attachScript":      executeAttachScript(command, in: scene, onLog: onLog)
            case "defineAnimation":   executeDefineAnimation(command, onLog: onLog)
            case "setDefaultAnimation": executeSetDefaultAnimation(command, in: scene, onLog: onLog)
            case "playAnimation":     executePlayAnimation(command, in: scene, onLog: onLog)
            case "setCharacter":      executeSetCharacter(command, in: scene, onLog: onLog)
            case "generateTexture":   dispatchGenerateTexture(command, in: scene, settings: settings, onLog: onLog)
            case "generateSound":     dispatchGenerateSound(command, settings: settings, onLog: onLog)
            default:
                onLog("Warning: Unknown action \"\(action)\".")
            }
        }

        return executed
    }

    // MARK: - Field helpers

    private func float(_ dict: [String: Any], _ key: String) -> Float? {
        if let d = dict[key] as? Double { return Float(d) }
        if let i = dict[key] as? Int { return Float(i) }
        return nil
    }

    private func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let i = dict[key] as? Int { return i }
        if let d = dict[key] as? Double { return Int(d) }
        return nil
    }

    private func color4(_ dict: [String: Any], _ key: String) -> simd_float4? {
        guard let c = dict[key] as? [Double], c.count == 4 else { return nil }
        return simd_float4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
    }

    private func target(_ dict: [String: Any], in scene: Scene,
                        onLog: (String) -> Void) -> Node? {
        guard let name = dict["targetName"] as? String else {
            onLog("Error: Command requires targetName.")
            return nil
        }
        guard let node = findNode(named: name, in: scene.rootNode) else {
            onLog("Warning: Node \"\(name)\" not found.")
            return nil
        }
        return node
    }

    // MARK: - Node lifecycle commands

    private func executeCreateNode(_ cmd: [String: Any], in scene: Scene,
                                   onLog: (String) -> Void) {
        guard let type = cmd["type"] as? String,
              let name = cmd["name"] as? String else {
            onLog("Error: createNode requires type and name.")
            return
        }

        let node: Node
        switch type {
        case "SpriteNode":    node = SpriteNode()
        case "ShapeNode":     node = ShapeNode()
        case "TextNode":      node = TextNode()
        case "CameraNode":    node = CameraNode()
        case "AudioNode":     node = AudioNode()
        case "CollisionNode": node = CollisionNode()
        case "TimerNode":     node = TimerNode()
        case "ParticleNode":  node = ParticleNode()
        case "TileMapNode":   node = TileMapNode()
        case "Node":          node = Node()
        default:
            onLog("Error: Unknown node type \"\(type)\".")
            return
        }

        node.name = name
        if let x = float(cmd, "x") { node.position.x = x }
        if let y = float(cmd, "y") { node.position.y = y }
        if let z = int(cmd, "zIndex") { node.zIndex = z }
        if let groups = cmd["groups"] as? [String] { node.groups = Set(groups) }

        // Type extras.
        if let shape = node as? ShapeNode {
            if let c = color4(cmd, "color") { shape.color = (c.x, c.y, c.z, c.w) }
            if let w = float(cmd, "width") { shape.shapeWidth = w }
            if let h = float(cmd, "height") { shape.shapeHeight = h }
        }
        if let text = node as? TextNode {
            if let t = cmd["text"] as? String { text.text = t }
            if let s = float(cmd, "fontSize") { text.fontSize = CGFloat(s) }
        }
        if let audio = node as? AudioNode {
            if let f = cmd["soundFile"] as? String { audio.soundFile = f }
            if let p = cmd["playOnStart"] as? Bool { audio.playOnStart = p }
            if let l = cmd["loops"] as? Bool { audio.loops = l }
        }
        if let trigger = node as? CollisionNode {
            if let s = cmd["triggerSignal"] as? String { trigger.triggerSignal = s }
            if let w = float(cmd, "width"), let h = float(cmd, "height") {
                trigger.triggerSize = simd_float2(w, h)
            }
        }
        if let timer = node as? TimerNode {
            if let w = float(cmd, "waitTime") { timer.waitTime = w }
            if let o = cmd["oneShot"] as? Bool { timer.oneShot = o }
            if let a = cmd["autostart"] as? Bool { timer.autostart = a }
            if let s = cmd["signal"] as? String { timer.timeoutSignal = s }
        }

        // Sprites and tile maps need a texture to be visible — give
        // them the editor's default so AI creations show up instantly.
        if let sprite = node as? SpriteNode, sprite.texture == nil,
           !(node is ShapeNode), !(node is TextNode) {
            sprite.texture = defaultTextureProvider?() as? (any MTLTexture)
        }
        if let tileMap = node as? TileMapNode, tileMap.texture == nil {
            tileMap.texture = defaultTextureProvider?() as? (any MTLTexture)
        }

        let parent: Node
        if let parentName = cmd["parentName"] as? String,
           let found = findNode(named: parentName, in: scene.rootNode) {
            parent = found
        } else {
            parent = scene.rootNode
        }
        parent.addChild(node)

        onLog("Created \(type) \"\(name)\" under \"\(parent.name)\".")
    }

    private func executeDeleteNode(_ cmd: [String: Any], in scene: Scene,
                                   onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog) else { return }
        guard node !== scene.rootNode else {
            onLog("Error: Cannot delete the scene root.")
            return
        }
        PhysicsWorld.current?.removeBodies(ownedBy: node)
        node.removeFromParent()
        onLog("Deleted \"\(node.name)\".")
    }

    // MARK: - Property commands

    private func executeUpdateProperty(_ cmd: [String: Any], in scene: Scene,
                                       onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let property = cmd["property"] as? String,
              let value = float(cmd, "value") else {
            onLog("Error: updateProperty requires targetName, property, and value.")
            return
        }

        switch property {
        case "positionX": node.position.x = value
        case "positionY": node.position.y = value
        case "rotation":  node.rotation = value
        case "scaleX":    node.scale.x = value
        case "scaleY":    node.scale.y = value
        case "zIndex":    node.zIndex = Int(value)
        case "visible":   node.isEnabled = value != 0
        case "zoom":
            guard let camera = node as? CameraNode else {
                onLog("Warning: \"\(node.name)\" is not a camera.")
                return
            }
            camera.zoom = value
        default:
            onLog("Warning: Unknown property \"\(property)\".")
            return
        }

        onLog("Set \"\(node.name)\".\(property) = \(value)")
    }

    private func executeSetColor(_ cmd: [String: Any], in scene: Scene,
                                 onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let c = color4(cmd, "color") else {
            onLog("Error: setColor requires targetName and color [r,g,b,a].")
            return
        }

        if let shape = node as? ShapeNode {
            shape.color = (c.x, c.y, c.z, c.w)
        } else if let text = node as? TextNode {
            text.textColor = c
        } else if let sprite = node as? SpriteNode {
            sprite.modulate = c
        } else {
            onLog("Warning: \"\(node.name)\" has nothing to color.")
            return
        }
        onLog("Colored \"\(node.name)\".")
    }

    private func executeSetText(_ cmd: [String: Any], in scene: Scene,
                                onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let text = node as? TextNode,
              let value = cmd["text"] as? String else {
            onLog("Error: setText requires targetName (a TextNode) and text.")
            return
        }
        text.text = value
        if let size = float(cmd, "fontSize") { text.fontSize = CGFloat(size) }
        onLog("Set \"\(node.name)\" text to \"\(value)\".")
    }

    // MARK: - Physics commands

    private func executeAddPhysicsBody(_ cmd: [String: Any], in scene: Scene,
                                       onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let sizeX = float(cmd, "sizeX"),
              let sizeY = float(cmd, "sizeY") else {
            onLog("Error: addPhysicsBody requires targetName, sizeX, sizeY.")
            return
        }

        let isDynamic = cmd["isDynamic"] as? Bool ?? true
        let body: PhysicsBody
        if let existing = node.physicsBody {
            body = existing
            body.size = simd_float2(sizeX, sizeY)
            body.isDynamic = isDynamic
        } else {
            body = PhysicsBody(size: simd_float2(sizeX, sizeY), isDynamic: isDynamic)
            node.addPhysicsBody(body)
        }
        if let g = float(cmd, "gravityScale") { body.gravityScale = g }
        if let l = int(cmd, "collisionLayer") { body.collisionLayer = UInt32(truncatingIfNeeded: l) }
        if let m = int(cmd, "collisionMask") { body.collisionMask = UInt32(truncatingIfNeeded: m) }

        onLog("Physics body on \"\(node.name)\": \(sizeX)×\(sizeY), \(isDynamic ? "dynamic" : "static").")
    }

    private func executeSetVelocity(_ cmd: [String: Any], in scene: Scene,
                                    onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let x = float(cmd, "x"), let y = float(cmd, "y") else {
            onLog("Error: setVelocity requires targetName, x, y.")
            return
        }
        guard let body = node.physicsBody else {
            onLog("Warning: \"\(node.name)\" has no physics body.")
            return
        }
        body.velocity = simd_float2(x, y)
        onLog("Set \"\(node.name)\" velocity to (\(x), \(y)).")
    }

    private func executeSetGravity(_ cmd: [String: Any], in scene: Scene,
                                   onLog: (String) -> Void) {
        guard let x = float(cmd, "x"), let y = float(cmd, "y") else {
            onLog("Error: setGravity requires x and y.")
            return
        }
        // Persist on the scene (saved to the scene file) AND apply to
        // the live physics world so it takes effect immediately.
        scene.gravity = simd_float2(x, y)
        guard let world = PhysicsWorld.current else {
            onLog("Warning: No physics world available.")
            return
        }
        world.gravity = simd_float2(x, y)
        onLog("World gravity set to (\(x), \(y)) — saved with the scene.")
    }

    // MARK: - Particles / TileMap / Camera / Timer commands

    private func executeConfigureParticles(_ cmd: [String: Any], in scene: Scene,
                                           onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let particles = node as? ParticleNode else {
            onLog("Error: configureParticles requires targetName (a ParticleNode).")
            return
        }

        if let v = int(cmd, "amount") { particles.amount = v }
        if let v = float(cmd, "lifetime") { particles.lifetime = v }
        if let v = cmd["oneShot"] as? Bool { particles.oneShot = v }
        if let v = float(cmd, "direction") { particles.direction = v }
        if let v = float(cmd, "spread") { particles.spread = v }
        if let v = float(cmd, "initialVelocity") { particles.initialVelocity = v }
        if let gx = float(cmd, "gravityX"), let gy = float(cmd, "gravityY") {
            particles.gravity = simd_float2(gx, gy)
        }
        if let v = float(cmd, "startScale") { particles.startScale = v }
        if let v = float(cmd, "endScale") { particles.endScale = v }
        if let c = color4(cmd, "startColor") { particles.startColor = c }
        if let c = color4(cmd, "endColor") { particles.endColor = c }
        if let v = cmd["emitting"] as? Bool {
            particles.emitting = v
            if v { particles.restart() }
        }

        onLog("Configured particles on \"\(node.name)\".")
    }

    private func executeConfigureTileMap(_ cmd: [String: Any], in scene: Scene,
                                         onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let tileMap = node as? TileMapNode else {
            onLog("Error: configureTileMap requires targetName (a TileMapNode).")
            return
        }

        // A named tile set applies first; explicit fields override it.
        if let setName = cmd["tileSet"] as? String {
            if let tileSet = TileSetLibrary.tileSet(named: setName) {
                tileMap.apply(tileSet)
                if let textureName = tileMap.textureName,
                   let texture = SpriteNode.textureResolver?(textureName) {
                    tileMap.texture = texture
                }
            } else {
                onLog("Warning: tile set \"\(setName)\" not found.")
            }
        }

        if let v = float(cmd, "tileWidth") { tileMap.tileWidth = v }
        if let v = float(cmd, "tileHeight") { tileMap.tileHeight = v }
        if let v = int(cmd, "atlasColumns") { tileMap.atlasColumns = v }
        if let v = int(cmd, "atlasRows") { tileMap.atlasRows = v }
        if let solids = cmd["solidTiles"] as? [Int] { tileMap.solidTiles = Set(solids) }

        onLog("Configured tile map \"\(node.name)\".")
    }

    private func executePaintTiles(_ cmd: [String: Any], in scene: Scene,
                                   onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let tileMap = node as? TileMapNode else {
            onLog("Error: paintTiles requires targetName (a TileMapNode).")
            return
        }

        if let triples = cmd["tiles"] as? [[Int]] {
            var painted = 0
            for triple in triples where triple.count == 3 {
                tileMap.setTile(x: triple[0], y: triple[1], tileIndex: triple[2])
                painted += 1
            }
            onLog("Painted \(painted) tiles on \"\(node.name)\".")
        } else if let x = int(cmd, "x"), let y = int(cmd, "y"),
                  let w = int(cmd, "width"), let h = int(cmd, "height"),
                  let index = int(cmd, "tileIndex") {
            tileMap.fillRect(x: x, y: y, width: w, height: h, tileIndex: index)
            onLog("Filled \(w)×\(h) tiles on \"\(node.name)\".")
        } else {
            onLog("Error: paintTiles needs \"tiles\" triples or x/y/width/height/tileIndex.")
        }
    }

    private func executeSetCameraFollow(_ cmd: [String: Any], in scene: Scene,
                                        onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let camera = node as? CameraNode,
              let followTarget = cmd["followTarget"] as? String else {
            onLog("Error: setCameraFollow requires targetName (a CameraNode) and followTarget.")
            return
        }
        camera.followTargetName = followTarget
        camera.followSmoothing = float(cmd, "smoothing") ?? 0
        onLog("Camera \"\(node.name)\" now follows \"\(followTarget)\".")
    }

    private func executeConfigureTimer(_ cmd: [String: Any], in scene: Scene,
                                       onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let timer = node as? TimerNode else {
            onLog("Error: configureTimer requires targetName (a TimerNode).")
            return
        }
        if let w = float(cmd, "waitTime") { timer.waitTime = w }
        if let o = cmd["oneShot"] as? Bool { timer.oneShot = o }
        if let a = cmd["autostart"] as? Bool { timer.autostart = a }
        if let s = cmd["signal"] as? String { timer.timeoutSignal = s }
        onLog("Configured timer \"\(node.name)\" (\(timer.waitTime)s → \"\(timer.timeoutSignal)\").")
    }

    // MARK: - Prefab commands

    private func executeSavePrefab(_ cmd: [String: Any], in scene: Scene,
                                   onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let prefabName = cmd["prefabName"] as? String else {
            onLog("Error: savePrefab requires targetName and prefabName.")
            return
        }
        if PrefabLibrary.save(node, named: prefabName) {
            onLog("Saved \"\(node.name)\" as prefab \"\(prefabName)\".")
        } else {
            onLog("Error: Could not save prefab \"\(prefabName)\".")
        }
    }

    private func executeSpawnPrefab(_ cmd: [String: Any], in scene: Scene,
                                    onLog: (String) -> Void) {
        guard let prefabName = cmd["prefabName"] as? String,
              let x = float(cmd, "x"), let y = float(cmd, "y") else {
            onLog("Error: spawnPrefab requires prefabName, x, y.")
            return
        }
        guard let instance = PrefabLibrary.instantiate(named: prefabName) else {
            onLog("Warning: Prefab \"\(prefabName)\" not found.")
            return
        }

        if let name = cmd["name"] as? String { instance.name = name }
        instance.position = simd_float2(x, y)

        // Fresh instances have no textures (not JSON-serializable).
        assignDefaultTextures(to: instance)

        let parent: Node
        if let parentName = cmd["parentName"] as? String,
           let found = findNode(named: parentName, in: scene.rootNode) {
            parent = found
        } else {
            parent = scene.rootNode
        }
        parent.addChild(instance)

        onLog("Spawned prefab \"\(prefabName)\" as \"\(instance.name)\" at (\(x), \(y)).")
    }

    private func assignDefaultTextures(to node: Node) {
        if let sprite = node as? SpriteNode, sprite.texture == nil,
           !(node is ShapeNode), !(node is TextNode) {
            sprite.texture = defaultTextureProvider?() as? (any MTLTexture)
        }
        if let tileMap = node as? TileMapNode, tileMap.texture == nil {
            tileMap.texture = defaultTextureProvider?() as? (any MTLTexture)
        }
        for child in node.children {
            assignDefaultTextures(to: child)
        }
    }

    private func executeAddToGroup(_ cmd: [String: Any], in scene: Scene,
                                   onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let group = cmd["group"] as? String else {
            onLog("Error: addToGroup requires targetName and group.")
            return
        }
        node.groups.insert(group)
        onLog("Added \"\(node.name)\" to group \"\(group)\".")
    }

    // MARK: - Animation commands

    private func executeDefineAnimation(_ cmd: [String: Any], onLog: (String) -> Void) {
        guard let name = cmd["name"] as? String,
              let gridWidth = int(cmd, "gridWidth"),
              let gridHeight = int(cmd, "gridHeight"),
              let startFrame = int(cmd, "startFrame"),
              let endFrame = int(cmd, "endFrame") else {
            onLog("Error: defineAnimation requires name, gridWidth, gridHeight, startFrame, endFrame.")
            return
        }

        var clip = AnimationClip(
            name: name,
            gridWidth: max(gridWidth, 1),
            gridHeight: max(gridHeight, 1),
            startFrame: max(startFrame, 0),
            endFrame: max(endFrame, startFrame),
            fps: float(cmd, "fps") ?? 8,
            loops: cmd["loops"] as? Bool ?? true
        )
        clip.character = cmd["character"] as? String
        clip.textureName = cmd["textureName"] as? String

        if AnimationLibrary.save(clip) {
            onLog("Defined animation \"\(clip.qualifiedName)\" (\(clip.frameCount) frames @ \(clip.fps) fps\(clip.textureName.map { ", sheet: \($0)" } ?? "")).")
        } else {
            onLog("Error: Could not save animation \"\(name)\".")
        }
    }

    private func executeSetDefaultAnimation(_ cmd: [String: Any], in scene: Scene,
                                            onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let sprite = node as? SpriteNode,
              let animation = cmd["animation"] as? String else {
            onLog("Error: setDefaultAnimation requires targetName (a SpriteNode) and animation.")
            return
        }
        sprite.defaultAnimationName = animation
        onLog("\"\(node.name)\" auto-plays \"\(animation)\" on scene start.")
    }

    private func executePlayAnimation(_ cmd: [String: Any], in scene: Scene,
                                      onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let sprite = node as? SpriteNode,
              let animation = cmd["animation"] as? String else {
            onLog("Error: playAnimation requires targetName (a SpriteNode) and animation.")
            return
        }
        sprite.playAnimation(animation)
        onLog("Playing \"\(animation)\" on \"\(node.name)\".")
    }

    private func executeSetCharacter(_ cmd: [String: Any], in scene: Scene,
                                     onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let sprite = node as? SpriteNode,
              let character = cmd["character"] as? String else {
            onLog("Error: setCharacter requires targetName (a SpriteNode) and character.")
            return
        }
        sprite.characterName = character.isEmpty ? nil : character
        if sprite.defaultAnimationName == nil,
           AnimationLibrary.clip(named: "\(character)/idle") != nil {
            sprite.defaultAnimationName = "idle"
        }
        onLog("Character \"\(character)\" attached to \"\(node.name)\".")
    }

    // MARK: - Behavior / script commands

    private func executeAddRule(_ cmd: [String: Any], in scene: Scene,
                                onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog) else { return }

        guard let eventDict = cmd["event"] as? [String: Any],
              let actionDicts = cmd["actions"] as? [[String: Any]] else {
            onLog("Error: addRule requires event and actions.")
            return
        }

        let ruleDict: [String: Any] = ["event": eventDict, "actions": actionDicts]
        guard let newRule = SceneDeserializer.buildRule(from: ruleDict) else {
            onLog("Error: Could not build rule from AI command.")
            return
        }

        // Add the rule to the node's first non-script behavior.
        if let behavior = node.behaviors.first(where: { !($0 is ScriptBehavior) }) {
            behavior.rules.append(newRule)
        } else {
            node.addBehavior(Behavior(rules: [newRule]))
        }

        onLog("Added rule to \"\(node.name)\": \(newRule.event.displayName) → \(newRule.actions.map { $0.displayName }.joined(separator: ", "))")
    }

    private func executeAttachScript(_ cmd: [String: Any], in scene: Scene,
                                     onLog: (String) -> Void) {
        guard let node = target(cmd, in: scene, onLog: onLog),
              let code = cmd["code"] as? String else {
            onLog("Error: attachScript requires targetName and code.")
            return
        }

        // Generate a script filename from the node name.
        let scriptName = "\(node.name)_AI_Script.js"

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

    // MARK: - Async Command Dispatchers

    private func dispatchGenerateTexture(_ cmd: [String: Any],
                                         in scene: Scene,
                                         settings: AISettings,
                                         onLog: @escaping @MainActor (String) -> Void) {
        guard let targetName = cmd["targetName"] as? String,
              let imagePrompt = cmd["prompt"] as? String else {
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

    private func dispatchGenerateSound(_ cmd: [String: Any],
                                       settings: AISettings,
                                       onLog: @escaping @MainActor (String) -> Void) {
        guard let soundPrompt = cmd["prompt"] as? String else {
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
