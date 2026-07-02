//
//  PhysicsWorld.swift
//  IngotEngine
//
//  The physics simulation. Each fixed step it:
//
//    1. Integrates velocities (with gravity) for dynamic bodies.
//    2. Finds overlapping pairs via a spatial hash broadphase
//       (O(n) buckets instead of O(n²) brute force).
//    3. Filters pairs by collision layer/mask bitfields.
//    4. Fires trigger signals (Area2D-style) on overlap ENTER.
//    5. Emits collision events (global, per-node, and behavior flags).
//    6. Resolves dynamic-vs-static penetration along the shortest axis.
//

import CoreGraphics
import Foundation
import simd

class PhysicsWorld {

    /// The world owned by the running Engine. Behaviors use this to
    /// register bodies for runtime-spawned nodes and to unregister
    /// bodies when a node is destroyed (mirrors InputManager.shared).
    static weak var current: PhysicsWorld?

    /// Constant acceleration applied to dynamic bodies, in pixels/s².
    /// (0, 0) suits top-down games; a platformer sets (0, -980).
    var gravity = simd_float2(0, 0)

    /// All physics bodies registered in this world.
    private(set) var bodies: [PhysicsBody] = []

    /// Overlapping pairs from the previous step, used to detect
    /// overlap ENTER for trigger signals.
    private var previousOverlaps: Set<PairKey> = []

    /// An unordered pair of bodies, hashable for overlap bookkeeping.
    private struct PairKey: Hashable {
        let a: ObjectIdentifier
        let b: ObjectIdentifier

        init(_ bodyA: PhysicsBody, _ bodyB: PhysicsBody) {
            let idA = ObjectIdentifier(bodyA)
            let idB = ObjectIdentifier(bodyB)
            if idA < idB { a = idA; b = idB } else { a = idB; b = idA }
        }
    }

    /// A cell coordinate in the spatial hash grid.
    private struct GridKey: Hashable {
        let x: Int
        let y: Int
    }

    /// Broadphase cell size in pixels. Bodies are inserted into every
    /// cell their AABB touches; only bodies sharing a cell are pair-checked.
    var broadphaseCellSize: Float = 128

    /// Registers a body so it participates in collision detection.
    func addBody(_ body: PhysicsBody) {
        // Never register the same body twice (runtime spawns can race
        // with scene re-registration).
        guard !bodies.contains(where: { $0 === body }) else { return }
        bodies.append(body)
    }

    /// Unregisters a single body (e.g., when its node is destroyed).
    func removeBody(_ body: PhysicsBody) {
        bodies.removeAll { $0 === body }
    }

    /// Unregisters the bodies of a node and its whole subtree.
    func removeBodies(ownedBy node: Node) {
        var owners: Set<ObjectIdentifier> = [ObjectIdentifier(node)]
        for descendant in node.allDescendants() {
            owners.insert(ObjectIdentifier(descendant))
        }
        bodies.removeAll { body in
            guard let owner = body.owner else { return true }  // Drop orphans too.
            return owners.contains(ObjectIdentifier(owner))
        }
    }

    /// Removes all bodies. Called when switching scenes.
    func removeAllBodies() {
        bodies.removeAll()
        previousOverlaps.removeAll()
    }

    /// Whether two bodies' layer/mask bitfields allow them to interact.
    /// Matches Godot's semantics: A scans B when A.mask includes a layer
    /// B occupies (or vice versa).
    private func layersInteract(_ a: PhysicsBody, _ b: PhysicsBody) -> Bool {
        (a.collisionMask & b.collisionLayer) != 0 ||
        (b.collisionMask & a.collisionLayer) != 0
    }

    /// Runs integration, collision detection, and resolution for one
    /// fixed time step.
    func update(deltaTime: CFTimeInterval) {
        let dt = Float(deltaTime)

        // --- 1. Integrate velocities for dynamic bodies ---
        for body in bodies where body.isDynamic {
            guard let owner = body.owner else { continue }
            body.velocity += gravity * body.gravityScale * dt
            owner.position += body.velocity * dt
        }

        // --- 2. Broadphase: spatial hash ---
        //
        // Each body is inserted into every grid cell its AABB touches.
        // Candidate pairs come only from bodies sharing a cell, so two
        // bodies on opposite ends of a big level are never compared.
        var grid: [GridKey: [Int]] = [:]
        let cell = CGFloat(max(broadphaseCellSize, 1))

        for (index, body) in bodies.enumerated() {
            let box = body.boundingBox
            guard box != .zero else { continue }
            let minX = Int(floor(box.minX / cell)), maxX = Int(floor(box.maxX / cell))
            let minY = Int(floor(box.minY / cell)), maxY = Int(floor(box.maxY / cell))
            for gx in minX...maxX {
                for gy in minY...maxY {
                    grid[GridKey(x: gx, y: gy), default: []].append(index)
                }
            }
        }

        // --- 3–6. Narrowphase per candidate pair ---
        var checkedPairs: Set<PairKey> = []
        var currentOverlaps: Set<PairKey> = []

        for (_, bucket) in grid where bucket.count > 1 {
            for i in 0..<bucket.count {
                for j in (i + 1)..<bucket.count {
                    let bodyA = bodies[bucket[i]]
                    let bodyB = bodies[bucket[j]]

                    // Skip static-vs-static.
                    if !bodyA.isDynamic && !bodyB.isDynamic { continue }

                    // Skip layer/mask-filtered pairs.
                    guard layersInteract(bodyA, bodyB) else { continue }

                    // Bodies spanning multiple cells appear in several
                    // buckets — check each pair only once per step.
                    let pair = PairKey(bodyA, bodyB)
                    guard checkedPairs.insert(pair).inserted else { continue }

                    let boxA = bodyA.boundingBox
                    let boxB = bodyB.boundingBox
                    guard boxA.intersects(boxB) else { continue }

                    currentOverlaps.insert(pair)
                    let isEnter = !previousOverlaps.contains(pair)

                    // --- Triggers (Area2D-style): fire on ENTER, never resolve ---
                    if bodyA.isTrigger || bodyB.isTrigger {
                        if isEnter {
                            (bodyA.owner as? CollisionNode)?.fireTrigger()
                            (bodyB.owner as? CollisionNode)?.fireTrigger()
                        }
                        continue
                    }

                    // --- Collision events ---
                    EventBus.shared.emit("Collision")
                    if let nameA = bodyA.owner?.name { EventBus.shared.emit("Collision:\(nameA)") }
                    if let nameB = bodyB.owner?.name { EventBus.shared.emit("Collision:\(nameB)") }
                    bodyA.owner?.behaviors.forEach { $0.collisionThisFrame = true }
                    bodyB.owner?.behaviors.forEach { $0.collisionThisFrame = true }

                    // --- Collision resolution (dynamic vs static only) ---
                    // The dynamic body gets pushed out of the static one.
                    // If both are dynamic, we skip resolution for now.
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

                    resolve(dynamicBody: dynamicBody, against: staticBox)
                }
            }
        }

        previousOverlaps = currentOverlaps
    }

    // MARK: - Penetration resolution

    /// Pushes a dynamic body out of a static box along the SHORTEST
    /// overlap axis, and kills the velocity component pointing into
    /// the obstacle (so gravity doesn't accumulate through floors).
    ///
    /// WHY SHORTEST AXIS?
    ///
    /// When a player walks into the left side of a wall, the X overlap
    /// is tiny (they just crossed the edge this frame) while the Y
    /// overlap is large (the boxes have been vertically aligned for many
    /// frames). Pushing along Y would teleport the player to the top or
    /// bottom of the wall; pushing along the small X overlap nudges them
    /// back exactly out of the wall — walk into a wall, stop at its edge.
    private func resolve(dynamicBody: PhysicsBody, against staticBox: CGRect) {
        guard let owner = dynamicBody.owner else { return }

        // Recompute the dynamic body's box (it may have been pushed
        // by an earlier collision in this same step).
        let dynBox = dynamicBody.boundingBox

        // halfWidthSum − centerDistance = penetration depth per axis.
        let overlapX = Float(dynamicBody.size.x / 2 + Float(staticBox.width) / 2)
                       - abs(Float(dynBox.midX - staticBox.midX))
        let overlapY = Float(dynamicBody.size.y / 2 + Float(staticBox.height) / 2)
                       - abs(Float(dynBox.midY - staticBox.midY))

        guard overlapX > 0, overlapY > 0 else { return }

        if overlapX < overlapY {
            if dynBox.midX < staticBox.midX {
                owner.position.x -= overlapX
                if dynamicBody.velocity.x > 0 { dynamicBody.velocity.x = 0 }
            } else {
                owner.position.x += overlapX
                if dynamicBody.velocity.x < 0 { dynamicBody.velocity.x = 0 }
            }
        } else {
            if dynBox.midY < staticBox.midY {
                owner.position.y -= overlapY
                if dynamicBody.velocity.y > 0 { dynamicBody.velocity.y = 0 }
            } else {
                owner.position.y += overlapY
                if dynamicBody.velocity.y < 0 { dynamicBody.velocity.y = 0 }
            }
        }

        // No explicit updateTransform() call needed — Node.position
        // feeds into globalTransform (computed), which feeds into
        // boundingBox (computed). The next access in this loop will
        // see the corrected position automatically.
    }
}
