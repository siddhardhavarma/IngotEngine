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
import simd

class Scene {

    /// The root of this scene's node tree.
    var rootNode = Node()

    /// The camera that determines the rendering viewpoint.
    var activeCamera: CameraNode?

    /// World gravity for this scene in px/s² (platformer: (0, -980);
    /// top-down: (0, 0)). Saved in the scene file and applied to the
    /// physics world whenever this scene becomes current.
    var gravity = simd_float2(0, 0)

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

    /// Pushes this scene's world settings (gravity) into the physics
    /// world. Called by the Engine when the scene becomes current.
    func applyWorldSettings(to world: PhysicsWorld) {
        world.gravity = gravity
    }

    func registerPhysicsBodies(with world: PhysicsWorld) {
        registerBodiesRecursive(node: rootNode, world: world)
    }

    private func registerBodiesRecursive(node: Node, world: PhysicsWorld) {
        if let body = node.physicsBody {
            world.addBody(body)
        }
        // Tile maps carry one static body per solid tile.
        if let tileMap = node as? TileMapNode {
            for body in tileMap.collisionBodies {
                world.addBody(body)
            }
        }
        for child in node.children {
            registerBodiesRecursive(node: child, world: world)
        }
    }
}
