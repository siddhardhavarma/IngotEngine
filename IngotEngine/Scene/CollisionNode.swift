//
//  CollisionNode.swift
//  IngotEngine
//
//  §4.4 Scene System — An invisible trigger zone.
//
//  CollisionNode has a collision shape but no visual representation.
//  When another body enters its area, it emits a configurable signal
//  via the EventBus. Uses: door triggers, kill zones, checkpoints,
//  item pickup areas.
//

import Foundation
import simd

class CollisionNode: Node {

    /// The signal emitted when something collides with this node.
    var triggerSignal: String = "Triggered"

    /// The width and height of the collision area.
    var triggerSize: simd_float2 = simd_float2(100, 100) {
        didSet {
            // Keep the physics body in sync.
            if let body = physicsBody {
                body.size = triggerSize
            }
        }
    }

    override init() {
        super.init()
        name = "Trigger"

        // Create a static physics body by default.
        let body = PhysicsBody(size: triggerSize, isDynamic: false)
        addPhysicsBody(body)
    }

    /// Call this when a collision is detected (by PhysicsWorld or a behavior).
    func fireTrigger() {
        EventBus.shared.emit(triggerSignal)
    }
}
