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
//  §4.5 Vocabulary (MVP):
//    Events:  onActionHeld, everyFrame, onStart, onCollision, onSignal
//    Actions: move, rotate, emitSignal, playSound, setProperty, destroy
//

import AVFoundation
import Foundation

// ---------------------------------------------------------------------------
// GameEvent — the "when" of a rule (§4.5)
// ---------------------------------------------------------------------------
enum GameEvent: Equatable {
    /// True while a named input action is held (e.g., "move_left").
    case onActionHeld(String)

    /// True every frame — used for continuous behaviors.
    case everyFrame

    /// True only on the first frame the behavior runs.
    case onStart

    /// True the frame a collision is detected on this node.
    case onCollision

    /// True when a named signal is received via the EventBus.
    case onSignal(String)

    /// Human-readable label for the event sheet UI.
    var displayName: String {
        switch self {
        case .onActionHeld(let a): return "Action Held: \(a)"
        case .everyFrame:          return "Every Frame"
        case .onStart:             return "On Start"
        case .onCollision:         return "On Collision"
        case .onSignal(let s):     return "On Signal: \(s)"
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

    /// Remove the owner node from the scene tree.
    case destroy

    /// Human-readable label for the event sheet UI.
    var displayName: String {
        switch self {
        case .move(let x, let y):          return "Move (\(x), \(y))"
        case .rotate(let d):               return "Rotate \(d)°/s"
        case .emitSignal(let s):           return "Emit \"\(s)\""
        case .playSound(let f):            return "Play \"\(f)\""
        case .setProperty(let p, let v):   return "Set \(p) = \(v)"
        case .destroy:                     return "Destroy"
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
    /// Set externally by the PhysicsWorld via the EventBus.
    var collisionThisFrame = false

    init(rules: [Rule] = []) {
        self.rules = rules
    }

    func start() {}

    func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard let owner = owner else { return }
        let dt = Float(deltaTime)

        for rule in rules {
            let triggered: Bool

            switch rule.event {
            case .onActionHeld(let action):
                triggered = input.isActionPressed(action)

            case .everyFrame:
                triggered = true

            case .onStart:
                triggered = !startRulesFired
                if triggered { startRulesFired = true }

            case .onCollision:
                triggered = collisionThisFrame

            case .onSignal:
                // Signal-based events are handled via EventBus connections
                // set up when the behavior is attached. For the rule
                // evaluation loop, this is a no-op — the signal fires
                // the actions directly via the connection.
                triggered = false
            }

            guard triggered else { continue }

            for action in rule.actions {
                executeAction(action, on: owner, dt: dt)
            }
        }

        collisionThisFrame = false
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
            // Access the audio manager via the singleton pattern.
            // In a production engine, this would go through the Engine reference.
            if let url = Bundle.main.url(forResource: fileName, withExtension: nil) {
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
            default: break
            }

        case .destroy:
            owner.removeFromParent()
        }
    }
}
