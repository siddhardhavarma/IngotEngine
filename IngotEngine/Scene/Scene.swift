//
//  Scene.swift
//  IngotEngine
//
//  §4.4 Scene System — A self-contained screen of game content.
//
//  A Scene owns a rootNode tree and an optional camera. The Engine
//  calls its lifecycle methods in the order defined by §8.
//

import Foundation

class Scene {

    /// The root of this scene's node tree.
    var rootNode = Node()

    /// The camera that determines the rendering viewpoint.
    var activeCamera: CameraNode?

    // MARK: - Lifecycle (§8 frame loop)

    /// Called once per frame by the Engine.
    func update(deltaTime: CFTimeInterval, input: InputManager) {
        rootNode.update(deltaTime: deltaTime, input: input)
    }

    // MARK: - Tree queries

    /// Finds a node anywhere in the tree by name.
    func findNode(named name: String) -> Node? {
        if rootNode.name == name { return rootNode }
        return rootNode.findChild(named: name)
    }

    /// Finds all nodes in the given group.
    func findNodes(inGroup group: String) -> [Node] {
        var results: [Node] = []
        if rootNode.groups.contains(group) { results.append(rootNode) }
        results.append(contentsOf: rootNode.findChildren(inGroup: group))
        return results
    }

    // MARK: - Physics registration

    func registerPhysicsBodies(with world: PhysicsWorld) {
        registerBodiesRecursive(node: rootNode, world: world)
    }

    private func registerBodiesRecursive(node: Node, world: PhysicsWorld) {
        if let body = node.physicsBody {
            world.addBody(body)
        }
        for child in node.children {
            registerBodiesRecursive(node: child, world: world)
        }
    }
}
