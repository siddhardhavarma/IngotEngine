//
//  SceneDeserializer.swift
//  IngotEngine
//
//  §7 Data Model — Full scene deserialization from JSON.
//
//  Reconstructs the complete scene state: node tree, transforms,
//  physics bodies, behaviors, script attachments, sprite sheet
//  frames, particles, tile maps, timers, and camera references.
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
        case "CameraNode":    node = CameraNode()
        case "ShapeNode":     node = ShapeNode()
        case "TextNode":      node = TextNode()
        case "AudioNode":     node = AudioNode()
        case "CollisionNode": node = CollisionNode()
        case "TimerNode":     node = TimerNode()
        case "ParticleNode":  node = ParticleNode()
        case "TileMapNode":   node = TileMapNode()
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
        if let z = dict["zIndex"] as? Int { node.zIndex = z }
        if let groups = dict["groups"] as? [String] { node.groups = Set(groups) }

        // Type-specific.
        if let camera = node as? CameraNode {
            if let zoom = dict["zoom"] as? Double { camera.zoom = Float(zoom) }
            if let target = dict["followTarget"] as? String {
                camera.followTargetName = target
                camera.followSmoothing = Float(dict["followSmoothing"] as? Double ?? 0)
            }
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
            if let c = dict["textColor"] as? [Double], c.count == 4 {
                text.textColor = simd_float4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
            }
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

        if let timer = node as? TimerNode {
            if let w = dict["waitTime"] as? Double { timer.waitTime = Float(w) }
            if let o = dict["oneShot"] as? Bool { timer.oneShot = o }
            if let a = dict["autostart"] as? Bool { timer.autostart = a }
            if let s = dict["timeoutSignal"] as? String { timer.timeoutSignal = s }
        }

        if let particles = node as? ParticleNode,
           let p = dict["particles"] as? [String: Any] {
            if let v = p["emitting"] as? Bool { particles.emitting = v }
            if let v = p["amount"] as? Int { particles.amount = v }
            if let v = p["lifetime"] as? Double { particles.lifetime = Float(v) }
            if let v = p["oneShot"] as? Bool { particles.oneShot = v }
            if let v = p["direction"] as? Double { particles.direction = Float(v) }
            if let v = p["spread"] as? Double { particles.spread = Float(v) }
            if let v = p["initialVelocity"] as? Double { particles.initialVelocity = Float(v) }
            if let v = p["velocityRandomness"] as? Double { particles.velocityRandomness = Float(v) }
            if let gx = p["gravityX"] as? Double, let gy = p["gravityY"] as? Double {
                particles.gravity = simd_float2(Float(gx), Float(gy))
            }
            if let v = p["startScale"] as? Double { particles.startScale = Float(v) }
            if let v = p["endScale"] as? Double { particles.endScale = Float(v) }
            if let c = p["startColor"] as? [Double], c.count == 4 {
                particles.startColor = simd_float4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
            }
            if let c = p["endColor"] as? [Double], c.count == 4 {
                particles.endColor = simd_float4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
            }
            if let v = p["angularVelocity"] as? Double { particles.angularVelocityDegrees = Float(v) }
        }

        if let tileMap = node as? TileMapNode,
           let t = dict["tileMap"] as? [String: Any] {
            if let w = t["tileWidth"] as? Double { tileMap.tileWidth = Float(w) }
            if let h = t["tileHeight"] as? Double { tileMap.tileHeight = Float(h) }
            if let c = t["atlasColumns"] as? Int { tileMap.atlasColumns = c }
            if let r = t["atlasRows"] as? Int { tileMap.atlasRows = r }
            if let solids = t["solidTiles"] as? [Int] { tileMap.solidTiles = Set(solids) }
            if let tileTriples = t["tiles"] as? [[Int]] {
                var tiles: [TileCoord: Int] = [:]
                for triple in tileTriples where triple.count == 3 {
                    tiles[TileCoord(x: triple[0], y: triple[1])] = triple[2]
                }
                tileMap.loadTiles(tiles)
            }
        }

        if let sprite = node as? SpriteNode {
            if let uv = dict["uvRect"] as? [Double], uv.count == 4 {
                sprite.uvRect = simd_float4(Float(uv[0]), Float(uv[1]), Float(uv[2]), Float(uv[3]))
            }
            if let m = dict["modulate"] as? [Double], m.count == 4 {
                sprite.modulate = simd_float4(Float(m[0]), Float(m[1]), Float(m[2]), Float(m[3]))
            }
        }

        // Physics body. CollisionNode already made its own trigger body
        // in init — reconfigure it instead of stacking a second one.
        if let bodyDict = dict["physicsBody"] as? [String: Any],
           let sizeX = bodyDict["sizeX"] as? Double,
           let sizeY = bodyDict["sizeY"] as? Double {
            let isDynamic = bodyDict["isDynamic"] as? Bool ?? true
            let body: PhysicsBody
            if let existing = node.physicsBody {
                body = existing
                body.size = simd_float2(Float(sizeX), Float(sizeY))
                body.isDynamic = isDynamic
            } else {
                body = PhysicsBody(size: simd_float2(Float(sizeX), Float(sizeY)),
                                   isDynamic: isDynamic)
                node.addPhysicsBody(body)
            }
            if let g = bodyDict["gravityScale"] as? Double { body.gravityScale = Float(g) }
            if let t = bodyDict["isTrigger"] as? Bool { body.isTrigger = t }
            if let l = bodyDict["collisionLayer"] as? Int { body.collisionLayer = UInt32(truncatingIfNeeded: l) }
            if let m = bodyDict["collisionMask"] as? Int { body.collisionMask = UInt32(truncatingIfNeeded: m) }
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

    /// Builds a Rule from an event/actions dictionary. Also used by the
    /// AI bridge to turn "addRule" commands into live rules.
    static func buildRule(from dict: [String: Any]) -> Rule? {
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
        case "onActionJustPressed":
            guard let action = dict["action"] as? String else { return nil }
            return .onActionJustPressed(action)
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
        case "setVelocity":
            guard let x = dict["x"] as? Double, let y = dict["y"] as? Double else { return nil }
            return .setVelocity(x: Float(x), y: Float(y))
        case "spawnPrefab":
            guard let name = dict["prefab"] as? String,
                  let x = dict["x"] as? Double, let y = dict["y"] as? Double else { return nil }
            return .spawnPrefab(name, x: Float(x), y: Float(y))
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
        if let tileMap = node as? TileMapNode, let tex = tileMap.texture {
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
        if let tileMap = node as? TileMapNode,
           let tex = textureMap[node.name] as? (any MTLTexture) {
            tileMap.texture = tex
        }
        for child in node.children {
            restoreTextures(textureMap, to: child)
        }
    }
}
