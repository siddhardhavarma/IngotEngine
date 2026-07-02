//
//  Behavior.swift
//  IngotEngine
//
//  §4.5 Behavior & Scripting — The Event-Action rule system.
//
//  A Behavior is a list of Rules, each pairing a GameEvent (condition)
//  with GameActions (effects). This is the shared model that both
//  the visual Event Sheet editor and JavaScript scripts compile down to.
//
//  §4.5 Vocabulary:
//    Events:  onActionHeld, onActionJustPressed, everyFrame, onStart,
//             onCollision, onSignal
//    Actions: move, rotate, emitSignal, playSound, setProperty,
//             setVelocity, spawnPrefab, destroy
//

import AVFoundation
import Foundation
import simd

// ---------------------------------------------------------------------------
// GameEvent — the "when" of a rule (§4.5)
// ---------------------------------------------------------------------------
enum GameEvent: Equatable {
    /// True while a named input action is held (e.g., "move_left").
    case onActionHeld(String)

    /// True only on the frame the action first goes down (jump, shoot).
    case onActionJustPressed(String)

    /// True every frame — used for continuous behaviors.
    case everyFrame

    /// True only on the first frame the behavior runs.
    case onStart

    /// True the frame a collision is detected on this node.
    case onCollision

    /// True the frame a named signal is received via the EventBus.
    /// Timers, triggers, and other rules emit these signals.
    case onSignal(String)

    /// Human-readable label for the event sheet UI.
    var displayName: String {
        switch self {
        case .onActionHeld(let a):        return "Action Held: \(a)"
        case .onActionJustPressed(let a): return "Action Pressed: \(a)"
        case .everyFrame:                 return "Every Frame"
        case .onStart:                    return "On Start"
        case .onCollision:                return "On Collision"
        case .onSignal(let s):            return "On Signal: \(s)"
        }
    }
}

// ---------------------------------------------------------------------------
// GameAction — the "then" of a rule (§4.5)
// ---------------------------------------------------------------------------
enum GameAction {
    /// Move by (x, y) pixels per second.
    case move(x: Float, y: Float)

    /// Rotate by degrees per second.
    case rotate(degreesPerSecond: Float)

    /// Emit a named signal on the EventBus.
    case emitSignal(String)

    /// Play a one-shot sound effect.
    case playSound(String)

    /// Set a named property on the owner node.
    case setProperty(String, Float)

    /// Set the owner's physics velocity in pixels/second (requires a
    /// PhysicsBody). Combine with world gravity for jumps: set a big
    /// +Y velocity once and let gravity pull the body back down.
    case setVelocity(x: Float, y: Float)

    /// Instantiate a prefab at (x, y) under the scene root.
    case spawnPrefab(String, x: Float, y: Float)

    /// Switch to another scene at the end of this frame
    /// (menu → level 1 → level 2 …).
    case changeScene(String)

    /// Remove the owner node from the scene tree.
    case destroy

    /// Human-readable label for the event sheet UI.
    var displayName: String {
        switch self {
        case .move(let x, let y):            return "Move (\(x), \(y))"
        case .rotate(let d):                 return "Rotate \(d)°/s"
        case .emitSignal(let s):             return "Emit \"\(s)\""
        case .playSound(let f):              return "Play \"\(f)\""
        case .setProperty(let p, let v):     return "Set \(p) = \(v)"
        case .setVelocity(let x, let y):     return "Velocity (\(x), \(y))"
        case .spawnPrefab(let n, let x, let y): return "Spawn \"\(n)\" at (\(x), \(y))"
        case .changeScene(let s):            return "Change Scene → \"\(s)\""
        case .destroy:                       return "Destroy"
        }
    }
}

// ---------------------------------------------------------------------------
// Rule — one event → many actions
// ---------------------------------------------------------------------------
struct Rule {
    let event: GameEvent
    let actions: [GameAction]
}

// ---------------------------------------------------------------------------
// Behavior — evaluates rules each frame
// ---------------------------------------------------------------------------
class Behavior {

    var rules: [Rule]
    weak var owner: Node?
    var hasStarted = false

    /// Tracks whether onStart rules have fired (they only fire once).
    private var startRulesFired = false

    /// Tracks whether this node had a collision this frame.
    /// Set externally by the PhysicsWorld.
    var collisionThisFrame = false

    /// Signals received since the last update, drained each frame.
    /// EventBus connections are wired lazily in start().
    private var pendingSignals: Set<String> = []
    private var connectedSignals: Set<String> = []

    init(rules: [Rule] = []) {
        self.rules = rules
    }

    func start() {
        connectSignalRules()
    }

    /// Subscribes to the EventBus for every onSignal rule so those
    /// events actually fire. Weak capture: a behavior discarded by an
    /// undo/scene-load leaves only a harmless no-op closure behind.
    private func connectSignalRules() {
        for rule in rules {
            if case .onSignal(let name) = rule.event, !connectedSignals.contains(name) {
                connectedSignals.insert(name)
                EventBus.shared.connect(to: name) { [weak self] in
                    self?.pendingSignals.insert(name)
                }
            }
        }
    }

    func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard let owner = owner else { return }
        let dt = Float(deltaTime)

        // Rules added after start() (by the AI copilot or event sheet)
        // may introduce new onSignal subscriptions.
        connectSignalRules()

        for rule in rules {
            let triggered: Bool

            switch rule.event {
            case .onActionHeld(let action):
                triggered = input.isActionPressed(action)

            case .onActionJustPressed(let action):
                triggered = input.isActionJustPressed(action)

            case .everyFrame:
                triggered = true

            case .onStart:
                triggered = !startRulesFired
                if triggered { startRulesFired = true }

            case .onCollision:
                triggered = collisionThisFrame

            case .onSignal(let name):
                triggered = pendingSignals.contains(name)
            }

            guard triggered else { continue }

            for action in rule.actions {
                executeAction(action, on: owner, dt: dt)
            }
        }

        collisionThisFrame = false
        pendingSignals.removeAll()
    }

    private func executeAction(_ action: GameAction, on owner: Node, dt: Float) {
        switch action {
        case .move(let x, let y):
            owner.position.x += x * dt
            owner.position.y += y * dt

        case .rotate(let degreesPerSecond):
            owner.rotation += (degreesPerSecond * .pi / 180.0) * dt

        case .emitSignal(let name):
            EventBus.shared.emit(name)

        case .playSound(let fileName):
            // Try the project's Assets/ first, then the app bundle.
            var url = Bundle.main.url(forResource: fileName, withExtension: nil)
            if let assetsDir = ProjectManager.shared.assetsURL {
                let assetURL = assetsDir.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: assetURL.path) {
                    url = assetURL
                }
            }
            if let url = url {
                let player = try? AVFoundation.AVAudioPlayer(contentsOf: url)
                player?.play()
            }

        case .setProperty(let property, let value):
            switch property {
            case "positionX": owner.position.x = value
            case "positionY": owner.position.y = value
            case "rotation":  owner.rotation = value
            case "scaleX":    owner.scale.x = value
            case "scaleY":    owner.scale.y = value
            case "zIndex":    owner.zIndex = Int(value)
            default: break
            }

        case .setVelocity(let x, let y):
            owner.physicsBody?.velocity = simd_float2(x, y)

        case .spawnPrefab(let name, let x, let y):
            guard let instance = PrefabLibrary.instantiate(named: name) else { break }
            instance.position = simd_float2(x, y)
            owner.sceneRoot.addChild(instance)
            // Register the new subtree's bodies with the running world.
            if let world = PhysicsWorld.current {
                registerBodies(of: instance, with: world)
            }

        case .changeScene(let name):
            Engine.current?.requestScene(named: name)

        case .destroy:
            // Unregister physics before removal so no orphaned body
            // keeps colliding at the origin.
            PhysicsWorld.current?.removeBodies(ownedBy: owner)
            owner.removeFromParent()
        }
    }

    private func registerBodies(of node: Node, with world: PhysicsWorld) {
        if let body = node.physicsBody { world.addBody(body) }
        if let tileMap = node as? TileMapNode {
            tileMap.collisionBodies.forEach { world.addBody($0) }
        }
        for child in node.children {
            registerBodies(of: child, with: world)
        }
    }
}
