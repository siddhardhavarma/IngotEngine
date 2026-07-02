//
//  SceneDeserializer.swift
//  IngotEngine
//
//  §7 Data Model — Full scene deserialization from JSON.
//
//  Reconstructs the complete scene state: node tree, transforms,
//  physics bodies, behaviors, script attachments, sprite sheet
//  frames, and camera references.
//
//  §12.1: Swift's Codable cannot decode heterogeneous [Node] arrays.
//  We dispatch on the "type" string manually for polymorphic decoding.
//

import Foundation
import MetalKit
import simd

struct SceneDeserializer {

    /// Parses a scene JSON string and rebuilds the full node tree.
    static func deserialize(jsonString: String) -> Node? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootDict = json["rootNode"] as? [String: Any] else {
            Log.error("SceneDeserializer: Could not parse JSON.")
            return nil
        }

        return buildNode(from: rootDict)
    }

    /// Restores the activeCamera reference on a Scene by matching
    /// the camera name from the serialized data.
    static func restoreActiveCamera(scene: Scene, fromJSON jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cameraName = json["activeCamera"] as? String else {
            return
        }

        // Walk the tree to find the CameraNode with that name.
        if let camera = scene.findNode(named: cameraName) as? CameraNode {
            scene.activeCamera = camera
        }
    }

    // MARK: - Node building (§12.1 polymorphic dispatch)

    private static func buildNode(from dict: [String: Any]) -> Node {
        let typeName = dict["type"] as? String ?? "Node"

        let node: Node
        switch typeName {
        case "SpriteNode":    node = SpriteNode()
        case "CameraNode":   node = CameraNode()
        case "ShapeNode":    node = ShapeNode()
        case "TextNode":     node = TextNode()
        case "AudioNode":    node = AudioNode()
        case "CollisionNode": node = CollisionNode()
        default:              node = Node()
        }

        // Identity.
        node.name = dict["name"] as? String ?? "Node"

        // Spatial properties.
        if let px = dict["positionX"] as? Double { node.position.x = Float(px) }
        if let py = dict["positionY"] as? Double { node.position.y = Float(py) }
        if let rot = dict["rotation"] as? Double { node.rotation = Float(rot) }
        if let sx = dict["scaleX"] as? Double { node.scale.x = Float(sx) }
        if let sy = dict["scaleY"] as? Double { node.scale.y = Float(sy) }

        // State.
        if let enabled = dict["enabled"] as? Bool { node.isEnabled = enabled }
        if let groups = dict["groups"] as? [String] { node.groups = Set(groups) }

        // Type-specific.
        if let camera = node as? CameraNode, let zoom = dict["zoom"] as? Double {
            camera.zoom = Float(zoom)
        }

        if let shape = node as? ShapeNode {
            if let c = dict["shapeColor"] as? [Double], c.count == 4 {
                shape.color = (Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
            }
            if let w = dict["shapeWidth"] as? Double { shape.shapeWidth = Float(w) }
            if let h = dict["shapeHeight"] as? Double { shape.shapeHeight = Float(h) }
        }

        if let text = node as? TextNode {
            if let t = dict["text"] as? String { text.text = t }
            if let s = dict["fontSize"] as? Double { text.fontSize = CGFloat(s) }
        }

        if let audio = node as? AudioNode {
            if let f = dict["soundFile"] as? String { audio.soundFile = f }
            if let p = dict["playOnStart"] as? Bool { audio.playOnStart = p }
            if let l = dict["loops"] as? Bool { audio.loops = l }
            if let v = dict["volume"] as? Double { audio.volume = Float(v) }
        }

        if let trigger = node as? CollisionNode {
            if let s = dict["triggerSignal"] as? String { trigger.triggerSignal = s }
            if let x = dict["triggerSizeX"] as? Double,
               let y = dict["triggerSizeY"] as? Double {
                trigger.triggerSize = simd_float2(Float(x), Float(y))
            }
        }

        if let sprite = node as? SpriteNode, let uv = dict["uvRect"] as? [Double], uv.count == 4 {
            sprite.uvRect = simd_float4(Float(uv[0]), Float(uv[1]), Float(uv[2]), Float(uv[3]))
        }

        // Physics body.
        if let bodyDict = dict["physicsBody"] as? [String: Any],
           let sizeX = bodyDict["sizeX"] as? Double,
           let sizeY = bodyDict["sizeY"] as? Double {
            let isDynamic = bodyDict["isDynamic"] as? Bool ?? true
            let body = PhysicsBody(size: simd_float2(Float(sizeX), Float(sizeY)),
                                   isDynamic: isDynamic)
            node.addPhysicsBody(body)
        }

        // Behaviors.
        if let behaviorDicts = dict["behaviors"] as? [[String: Any]] {
            for bDict in behaviorDicts {
                let bType = bDict["type"] as? String ?? ""

                if bType == "ScriptBehavior", let scriptName = bDict["scriptName"] as? String {
                    let script = ScriptBehavior(scriptName: scriptName)
                    node.addBehavior(script)
                } else if bType == "RuleBehavior", let ruleDicts = bDict["rules"] as? [[String: Any]] {
                    let rules = ruleDicts.compactMap { buildRule(from: $0) }
                    if !rules.isEmpty {
                        node.addBehavior(Behavior(rules: rules))
                    }
                }
            }
        }

        // Children (recursive).
        if let childDicts = dict["children"] as? [[String: Any]] {
            for childDict in childDicts {
                node.addChild(buildNode(from: childDict))
            }
        }

        return node
    }

    // MARK: - Rule building

    private static func buildRule(from dict: [String: Any]) -> Rule? {
        guard let eventDict = dict["event"] as? [String: Any],
              let actionDicts = dict["actions"] as? [[String: Any]] else {
            return nil
        }

        guard let event = buildEvent(from: eventDict) else { return nil }
        let actions = actionDicts.compactMap { buildAction(from: $0) }
        guard !actions.isEmpty else { return nil }

        return Rule(event: event, actions: actions)
    }

    private static func buildEvent(from dict: [String: Any]) -> GameEvent? {
        let type = dict["type"] as? String ?? ""
        switch type {
        case "onActionHeld":
            guard let action = dict["action"] as? String else { return nil }
            return .onActionHeld(action)
        case "everyFrame":  return .everyFrame
        case "onStart":     return .onStart
        case "onCollision": return .onCollision
        case "onSignal":
            guard let signal = dict["signal"] as? String else { return nil }
            return .onSignal(signal)
        default:
            return nil
        }
    }

    private static func buildAction(from dict: [String: Any]) -> GameAction? {
        let type = dict["type"] as? String ?? ""
        switch type {
        case "move":
            guard let x = dict["x"] as? Double, let y = dict["y"] as? Double else { return nil }
            return .move(x: Float(x), y: Float(y))
        case "rotate":
            guard let d = dict["degreesPerSecond"] as? Double else { return nil }
            return .rotate(degreesPerSecond: Float(d))
        case "emitSignal":
            guard let name = dict["name"] as? String else { return nil }
            return .emitSignal(name)
        case "playSound":
            guard let fileName = dict["fileName"] as? String else { return nil }
            return .playSound(fileName)
        case "setProperty":
            guard let prop = dict["property"] as? String,
                  let val = dict["value"] as? Double else { return nil }
            return .setProperty(prop, Float(val))
        case "destroy":
            return .destroy
        default:
            return nil
        }
    }

    // MARK: - Texture helpers (for undo — textures can't be JSON-serialized)

    static func collectTextures(from node: Node) -> [String: Any] {
        var map: [String: Any] = [:]
        if let sprite = node as? SpriteNode, let tex = sprite.texture {
            map[node.name] = tex
        }
        for child in node.children {
            map.merge(collectTextures(from: child)) { _, new in new }
        }
        return map
    }

    static func restoreTextures(_ textureMap: [String: Any], to node: Node) {
        if let sprite = node as? SpriteNode,
           let tex = textureMap[node.name] as? (any MTLTexture) {
            sprite.texture = tex
        }
        for child in node.children {
            restoreTextures(textureMap, to: child)
        }
    }
}
