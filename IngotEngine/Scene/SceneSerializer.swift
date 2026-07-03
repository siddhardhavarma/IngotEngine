//
//  SceneSerializer.swift
//  IngotEngine
//
//  §7 Data Model — Full scene serialization to JSON.
//
//  Captures the COMPLETE scene state: node tree, transforms, physics
//  bodies, behaviors (event-action rules), script attachments, sprite
//  sheet frames, particles, tile maps, timers, and camera references.
//  This is the data that gets saved to disk, sent to the AI copilot,
//  used for undo snapshots, and written into prefab files.
//

import Foundation
import simd

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

        // World settings. Zero gravity (the default) is omitted so
        // top-down scenes stay diff-clean.
        if scene.gravity != simd_float2(0, 0) {
            dict["gravity"] = [Double(scene.gravity.x), Double(scene.gravity.y)]
        }

        return jsonString(from: dict)
    }

    /// Serializes a single node subtree (used for prefabs and
    /// Node.duplicate()). Produces the same {"rootNode": ...} shape as
    /// full scenes so SceneDeserializer.deserialize can read it.
    static func serializeSubtree(_ node: Node) -> String {
        jsonString(from: ["rootNode": serializeNode(node)])
    }

    private static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                      options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Node serialization

    private static func serializeNode(_ node: Node) -> [String: Any] {
        // Subclass checks must come before their superclasses.
        let typeName: String
        if node is CollisionNode { typeName = "CollisionNode" }
        else if node is AudioNode { typeName = "AudioNode" }
        else if node is TimerNode { typeName = "TimerNode" }
        else if node is ParticleNode { typeName = "ParticleNode" }
        else if node is TileMapNode { typeName = "TileMapNode" }
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

        if node.zIndex != 0 {
            dict["zIndex"] = node.zIndex
        }

        if !node.groups.isEmpty {
            dict["groups"] = Array(node.groups)
        }

        // Type-specific properties.
        if let camera = node as? CameraNode {
            dict["zoom"] = Double(camera.zoom)
            if let target = camera.followTargetName {
                dict["followTarget"] = target
                dict["followSmoothing"] = Double(camera.followSmoothing)
            }
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
            dict["textColor"] = [Double(text.textColor.x), Double(text.textColor.y),
                                 Double(text.textColor.z), Double(text.textColor.w)]
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

        if let timer = node as? TimerNode {
            dict["waitTime"] = Double(timer.waitTime)
            dict["oneShot"] = timer.oneShot
            dict["autostart"] = timer.autostart
            dict["timeoutSignal"] = timer.timeoutSignal
        }

        if let particles = node as? ParticleNode {
            let particleDict: [String: Any] = [
                "emitting": particles.emitting,
                "amount": particles.amount,
                "lifetime": Double(particles.lifetime),
                "oneShot": particles.oneShot,
                "direction": Double(particles.direction),
                "spread": Double(particles.spread),
                "initialVelocity": Double(particles.initialVelocity),
                "velocityRandomness": Double(particles.velocityRandomness),
                "gravityX": Double(particles.gravity.x),
                "gravityY": Double(particles.gravity.y),
                "startScale": Double(particles.startScale),
                "endScale": Double(particles.endScale),
                "startColor": [Double(particles.startColor.x), Double(particles.startColor.y),
                               Double(particles.startColor.z), Double(particles.startColor.w)],
                "endColor": [Double(particles.endColor.x), Double(particles.endColor.y),
                             Double(particles.endColor.z), Double(particles.endColor.w)],
                "angularVelocity": Double(particles.angularVelocityDegrees),
            ]
            dict["particles"] = particleDict
        }

        if let tileMap = node as? TileMapNode {
            var tileMapDict: [String: Any] = [
                "tileWidth": Double(tileMap.tileWidth),
                "tileHeight": Double(tileMap.tileHeight),
                "atlasColumns": tileMap.atlasColumns,
                "atlasRows": tileMap.atlasRows,
                "solidTiles": Array(tileMap.solidTiles).sorted(),
                // Each tile as [x, y, index] — compact and diff-friendly.
                "tiles": tileMap.tiles
                    .map { [$0.key.x, $0.key.y, $0.value] }
                    .sorted { ($0[1], $0[0]) < ($1[1], $1[0]) },
            ]
            if let tileSetName = tileMap.tileSetName {
                tileMapDict["tileSet"] = tileSetName
            }
            dict["tileMap"] = tileMapDict
        }

        if let sprite = node as? SpriteNode {
            dict["uvRect"] = [
                Double(sprite.uvRect.x), Double(sprite.uvRect.y),
                Double(sprite.uvRect.z), Double(sprite.uvRect.w)
            ]
            if sprite.modulate != simd_float4(1, 1, 1, 1) {
                dict["modulate"] = [Double(sprite.modulate.x), Double(sprite.modulate.y),
                                    Double(sprite.modulate.z), Double(sprite.modulate.w)]
            }
            if let textureName = sprite.textureName {
                dict["textureName"] = textureName
            }
            if let animation = sprite.defaultAnimationName {
                dict["defaultAnimation"] = animation
            }
            if let character = sprite.characterName {
                dict["characterName"] = character
            }
        }

        if let tileMap = node as? TileMapNode, let textureName = tileMap.textureName {
            dict["textureName"] = textureName
        }

        // Physics body.
        if let body = node.physicsBody {
            var bodyDict: [String: Any] = [
                "sizeX": Double(body.size.x),
                "sizeY": Double(body.size.y),
                "isDynamic": body.isDynamic,
            ]
            if body.gravityScale != 1 { bodyDict["gravityScale"] = Double(body.gravityScale) }
            if body.isTrigger { bodyDict["isTrigger"] = true }
            if body.collisionLayer != 1 { bodyDict["collisionLayer"] = Int(body.collisionLayer) }
            if body.collisionMask != 0xFFFFFFFF { bodyDict["collisionMask"] = Int(body.collisionMask) }
            dict["physicsBody"] = bodyDict
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
        case .onActionJustPressed(let action):
            return ["type": "onActionJustPressed", "action": action]
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
        case .setVelocity(let x, let y):
            return ["type": "setVelocity", "x": Double(x), "y": Double(y)]
        case .spawnPrefab(let name, let x, let y):
            return ["type": "spawnPrefab", "prefab": name, "x": Double(x), "y": Double(y)]
        case .playAnimation(let name):
            return ["type": "playAnimation", "animation": name]
        case .changeScene(let name):
            return ["type": "changeScene", "scene": name]
        case .destroy:
            return ["type": "destroy"]
        }
    }
}
