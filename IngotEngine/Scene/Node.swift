//
//  Node.swift
//  IngotEngine
//
//  §4.4 Scene System — The base class for everything in the scene tree.
//
//  A Node represents a position/rotation/scale in the world. Nodes form a
//  tree: each node has one parent and zero or more children. A child's
//  transform is relative to its parent, so moving a parent automatically
//  moves all of its descendants.
//

import Foundation
import simd

class Node: NSObject {

    // MARK: - Identity

    /// A human-readable name for this node, shown in the editor's hierarchy.
    var name: String = "Node"

    /// Groups this node belongs to (e.g., "enemies", "collectibles").
    /// Used for batch operations like "destroy all enemies."
    var groups: Set<String> = []

    // MARK: - State

    /// When false, this node and all its children are skipped during
    /// update and rendering. Like "hiding" a subtree without removing it.
    var isEnabled: Bool = true

    /// Whether ready() has been called on this node.
    private var isReady = false

    // MARK: - Hierarchy

    private(set) var children: [Node] = []
    weak var parent: Node?

    func addChild(_ node: Node) {
        node.removeFromParent()
        node.parent = self
        children.append(node)
    }

    func removeFromParent() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    // MARK: - Behaviors

    private(set) var behaviors: [Behavior] = []

    func addBehavior(_ behavior: Behavior) {
        behavior.owner = self
        behaviors.append(behavior)
    }

    func removeBehaviors(where predicate: (Behavior) -> Bool) {
        behaviors.removeAll(where: predicate)
    }

    // MARK: - Physics

    var physicsBody: PhysicsBody?

    func addPhysicsBody(_ body: PhysicsBody) {
        body.owner = self
        physicsBody = body
    }

    // MARK: - Local spatial properties

    var position = simd_float2(0, 0)
    var rotation: Float = 0
    var scale = simd_float2(1, 1)

    // MARK: - Transforms

    var localTransform: simd_float4x4 {
        let t = translationMatrix(tx: position.x, ty: position.y)
        let r = rotationMatrix(angle: rotation)
        let s = scaleMatrix(sx: scale.x, sy: scale.y)
        return t * r * s
    }

    var globalTransform: simd_float4x4 {
        if let parent = parent {
            return parent.globalTransform * localTransform
        }
        return localTransform
    }

    // MARK: - Lifecycle

    /// Called once when the node first enters the active scene tree.
    /// Override in subclasses for one-time setup that depends on the
    /// node being fully configured (position set, children added, etc.).
    func ready() {
        // Base implementation does nothing.
    }

    /// Called once per frame. Fires ready() if needed, runs behaviors,
    /// then propagates to children. Skips disabled nodes entirely.
    func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard isEnabled else { return }

        // Fire ready() once, the first frame this node is updated.
        if !isReady {
            ready()
            isReady = true
        }

        // Run behaviors (with their own start/update lifecycle).
        for behavior in behaviors {
            if !behavior.hasStarted {
                behavior.start()
                behavior.hasStarted = true
            }
            behavior.update(deltaTime: deltaTime, input: input)
        }

        // Propagate to children.
        for child in children {
            child.update(deltaTime: deltaTime, input: input)
        }
    }

    // MARK: - Tree queries

    /// Recursively finds the first descendant with the given name.
    func findChild(named name: String) -> Node? {
        for child in children {
            if child.name == name { return child }
            if let found = child.findChild(named: name) { return found }
        }
        return nil
    }

    /// Recursively finds all descendants in the given group.
    func findChildren(inGroup group: String) -> [Node] {
        var results: [Node] = []
        for child in children {
            if child.groups.contains(group) {
                results.append(child)
            }
            results.append(contentsOf: child.findChildren(inGroup: group))
        }
        return results
    }

    /// Returns all descendants (flat list via depth-first traversal).
    func allDescendants() -> [Node] {
        var results: [Node] = []
        for child in children {
            results.append(child)
            results.append(contentsOf: child.allDescendants())
        }
        return results
    }
}
