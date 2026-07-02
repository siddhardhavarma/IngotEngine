//
//  PhysicsWorld.swift
//  IngotEngine
//
//  The physics simulation. Each frame it checks all registered bodies
//  for AABB overlaps, emits collision signals, and resolves dynamic-vs-static
//  collisions by pushing the dynamic body out along the shortest axis.
//

import CoreGraphics
import Foundation

class PhysicsWorld {

    /// All physics bodies registered in this world.
    private(set) var bodies: [PhysicsBody] = []

    /// Registers a body so it participates in collision detection.
    func addBody(_ body: PhysicsBody) {
        bodies.append(body)
    }

    /// Removes all bodies. Called when switching scenes.
    func removeAllBodies() {
        bodies.removeAll()
    }

    /// Runs collision detection and resolution for one frame.
    func update(deltaTime: CFTimeInterval) {

        for i in 0..<bodies.count {
            for j in (i + 1)..<bodies.count {
                let bodyA = bodies[i]
                let bodyB = bodies[j]

                // Skip static-vs-static.
                if !bodyA.isDynamic && !bodyB.isDynamic { continue }

                let boxA = bodyA.boundingBox
                let boxB = bodyB.boundingBox

                guard boxA.intersects(boxB) else { continue }

                // --- Collision detected ---
                EventBus.shared.emit("Collision")

                // --- Collision resolution (dynamic vs static only) ---
                // We only resolve when exactly one body is dynamic and the
                // other is static. The dynamic body gets pushed out of the
                // static one. If both are dynamic, we skip resolution for now.
                let dynamicBody: PhysicsBody
                let staticBox: CGRect

                if bodyA.isDynamic && !bodyB.isDynamic {
                    dynamicBody = bodyA
                    staticBox = boxB
                } else if bodyB.isDynamic && !bodyA.isDynamic {
                    dynamicBody = bodyB
                    staticBox = boxA
                } else {
                    // Both dynamic — skip resolution.
                    continue
                }

                // Recompute the dynamic body's box (it may have been pushed
                // by an earlier collision in this same frame).
                let dynBox = dynamicBody.boundingBox

                // --- Calculate overlap on each axis ---
                //
                //   overlapX = how far the boxes penetrate on X
                //   overlapY = how far the boxes penetrate on Y
                //
                //   halfWidthSum = halfA + halfB = the distance between
                //   centers when the boxes are exactly touching edge-to-edge.
                //   Subtract the actual center distance to get penetration.
                let overlapX = Float((dynamicBody.size.x / 2 + Float(staticBox.width) / 2))
                               - abs(Float(dynBox.midX - staticBox.midX))
                let overlapY = Float((dynamicBody.size.y / 2 + Float(staticBox.height) / 2))
                               - abs(Float(dynBox.midY - staticBox.midY))

                guard let owner = dynamicBody.owner else { continue }

                // --- Resolve along the SHORTEST overlap axis ---
                //
                // WHY SHORTEST AXIS?
                //
                // When a player walks into the left side of a wall, the
                // overlap might look like this:
                //
                //    ┌──────────┐
                //    │          │
                //    │  Player  │▓▓▓▓┌──────────┐
                //    │          │▓▓▓▓│          │
                //    └──────────┘▓▓▓▓│   Wall   │
                //               ▓▓▓▓│          │
                //               ▓▓▓▓└──────────┘
                //               ^^^^
                //            overlapX = 5px (small — player just entered)
                //            overlapY = 80px (large — boxes are vertically aligned)
                //
                // If we pushed along the Y axis (overlapY = 80px), the player
                // would teleport 80 pixels up or down — flying to the top or
                // bottom of the wall. That looks broken.
                //
                // Pushing along the X axis (overlapX = 5px) nudges the player
                // back 5 pixels to the left — exactly out of the wall. That's
                // the natural, expected behavior: walk into a wall, stop at
                // its edge.
                //
                // The shortest overlap is always the axis of most recent
                // penetration, because the player had to cross that edge
                // within the last frame. The longer overlap means the bodies
                // have been aligned on that axis for multiple frames.

                if overlapX < overlapY {
                    // Resolve on X axis.
                    // Push direction: if the dynamic body is to the LEFT of
                    // the static body (midX < midX), push it further left
                    // (negative). Otherwise push it right (positive).
                    if dynBox.midX < staticBox.midX {
                        owner.position.x -= overlapX
                    } else {
                        owner.position.x += overlapX
                    }
                } else {
                    // Resolve on Y axis.
                    if dynBox.midY < staticBox.midY {
                        owner.position.y -= overlapY
                    } else {
                        owner.position.y += overlapY
                    }
                }

                // No explicit updateTransform() call needed — Node.position
                // feeds into globalTransform (computed), which feeds into
                // boundingBox (computed). The next access in this loop will
                // see the corrected position automatically.
            }
        }
    }
}
