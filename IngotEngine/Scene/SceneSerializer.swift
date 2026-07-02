//
//  SceneSerializer.swift
//  IngotEngine
//
//  §7 Data Model — Full scene serialization to JSON.
//
//  Captures the COMPLETE scene state: node tree, transforms, physics
//  bodies, behaviors (event-action rules), script attachments, sprite
//  sheet frames, and camera references. This is the data that gets
//  saved to disk, sent to the AI copilot, and used for undo snapshots.
//

import Foundation

struct SceneSerializer {

    /// Serializes the entire scene (tree + metadata) to a JSON string.
    static func serialize(_ scene: Scene) -> String {
        var dict: [String: Any] = [
            "rootNode": serializeNode(scene.rootNode)
        ]

        // Save the active camera reference by name.
        if let cameraName = scene.activeCamera?.name {
            dict["activeCamera"] = cameraName
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                      options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return json
    }

    // MARK: - Node serialization

    private static func serializeNode(_ node: Node) -> [String: Any] {
        let typeName: String
        if node is CollisionNode { typeName = "CollisionNode" }
        else if node is AudioNode { typeName = "AudioNode" }
        else if node is TextNode { typeName = "TextNode" }
        else if node is ShapeNode { typeName = "ShapeNode" }
        else if node is CameraNode { typeName = "CameraNode" }
        else if node is SpriteNode { typeName = "SpriteNode" }
        else { typeName = "Node" }

        var dict: [String: Any] = [
            "name": node.name,
            "type": typeName,
            "positionX": Double(node.position.x),
            "positionY": Double(node.position.y),
            "rotation": Double(node.rotation),
            "scaleX": Double(node.scale.x),
            "scaleY": Double(node.scale.y),
            "enabled": node.isEnabled,
        ]

        if !node.groups.isEmpty {
            dict["groups"] = Array(node.groups)
        }

        // Type-specific properties.
        if let camera = node as? CameraNode {
            dict["zoom"] = Double(camera.zoom)
        }

        if let shape = node as? ShapeNode {
            dict["shapeColor"] = [Double(shape.color.r), Double(shape.color.g),
                                  Double(shape.color.b), Double(shape.color.a)]
            dict["shapeWidth"] = Double(shape.shapeWidth)
            dict["shapeHeight"] = Double(shape.shapeHeight)
        }

        if let text = node as? TextNode {
            dict["text"] = text.text
            dict["fontSize"] = Double(text.fontSize)
        }

        if let audio = node as? AudioNode {
            dict["soundFile"] = audio.soundFile
            dict["playOnStart"] = audio.playOnStart
            dict["loops"] = audio.loops
            dict["volume"] = Double(audio.volume)
        }

        if let trigger = node as? CollisionNode {
            dict["triggerSignal"] = trigger.triggerSignal
            dict["triggerSizeX"] = Double(trigger.triggerSize.x)
            dict["triggerSizeY"] = Double(trigger.triggerSize.y)
        }

        if let sprite = node as? SpriteNode {
            dict["uvRect"] = [
                Double(sprite.uvRect.x), Double(sprite.uvRect.y),
                Double(sprite.uvRect.z), Double(sprite.uvRect.w)
            ]
        }

        // Physics body.
        if let body = node.physicsBody {
            dict["physicsBody"] = [
                "sizeX": Double(body.size.x),
                "sizeY": Double(body.size.y),
                "isDynamic": body.isDynamic,
            ]
        }

        // Behaviors (event-action rules + script attachments).
        var behaviorDicts: [[String: Any]] = []
        for behavior in node.behaviors {
            if let script = behavior as? ScriptBehavior {
                behaviorDicts.append([
                    "type": "ScriptBehavior",
                    "scriptName": script.scriptName,
                ])
            } else if !behavior.rules.isEmpty {
                behaviorDicts.append([
                    "type": "RuleBehavior",
                    "rules": behavior.rules.map { serializeRule($0) },
                ])
            }
        }
        if !behaviorDicts.isEmpty {
            dict["behaviors"] = behaviorDicts
        }

        // Children.
        dict["children"] = node.children.map { serializeNode($0) }

        return dict
    }

    // MARK: - Rule serialization

    private static func serializeRule(_ rule: Rule) -> [String: Any] {
        return [
            "event": serializeEvent(rule.event),
            "actions": rule.actions.map { serializeAction($0) },
        ]
    }

    private static func serializeEvent(_ event: GameEvent) -> [String: Any] {
        switch event {
        case .onActionHeld(let action):
            return ["type": "onActionHeld", "action": action]
        case .everyFrame:
            return ["type": "everyFrame"]
        case .onStart:
            return ["type": "onStart"]
        case .onCollision:
            return ["type": "onCollision"]
        case .onSignal(let name):
            return ["type": "onSignal", "signal": name]
        }
    }

    private static func serializeAction(_ action: GameAction) -> [String: Any] {
        switch action {
        case .move(let x, let y):
            return ["type": "move", "x": Double(x), "y": Double(y)]
        case .rotate(let d):
            return ["type": "rotate", "degreesPerSecond": Double(d)]
        case .emitSignal(let name):
            return ["type": "emitSignal", "name": name]
        case .playSound(let fileName):
            return ["type": "playSound", "fileName": fileName]
        case .setProperty(let prop, let val):
            return ["type": "setProperty", "property": prop, "value": Double(val)]
        case .destroy:
            return ["type": "destroy"]
        }
    }
}
