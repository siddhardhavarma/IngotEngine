//
//  PhysicsTests.swift
//  EngineTests
//
//  Headless physics: gravity integration, dynamic-vs-static
//  resolution, trigger enter events, and layer/mask filtering —
//  all without a GPU or a window.
//

import XCTest
import simd
@testable import IngotEngineCore

final class PhysicsTests: XCTestCase {

    /// A node at a position with a body, pre-wired for a world.
    private func makeBody(x: Float, y: Float, size: Float,
                          dynamic: Bool) -> (node: Node, body: PhysicsBody) {
        let node = Node()
        node.position = simd_float2(x, y)
        let body = PhysicsBody(size: simd_float2(size, size), isDynamic: dynamic)
        node.addPhysicsBody(body)
        return (node, body)
    }

    func testDisabledNodesDoNotRegisterBodies() {
        let scene = Scene()

        let wall = Node()
        wall.addPhysicsBody(PhysicsBody(size: simd_float2(100, 100), isDynamic: false))
        scene.rootNode.addChild(wall)

        let hiddenWall = Node()
        hiddenWall.addPhysicsBody(PhysicsBody(size: simd_float2(100, 100), isDynamic: false))
        hiddenWall.isEnabled = false
        scene.rootNode.addChild(hiddenWall)

        // A disabled tile map's solid-tile colliders stay out too.
        let map = TileMapNode()
        map.solidTiles = [0]
        map.setTile(x: 0, y: 0, tileIndex: 0)
        map.isEnabled = false
        scene.rootNode.addChild(map)

        let world = PhysicsWorld()
        scene.registerPhysicsBodies(with: world)

        XCTAssertEqual(world.bodies.count, 1,
                       "Disabled nodes don't render, don't update — and must not collide")
    }

    func testGravityIntegratesVelocityAndPosition() {
        let world = PhysicsWorld()
        world.gravity = simd_float2(0, -100)

        let (node, body) = makeBody(x: 0, y: 100, size: 10, dynamic: true)
        world.addBody(body)

        world.update(deltaTime: 0.1)

        XCTAssertEqual(body.velocity.y, -10, accuracy: 0.001)
        XCTAssertLessThan(node.position.y, 100)
    }

    func testGravityScaleZeroIgnoresGravity() {
        let world = PhysicsWorld()
        world.gravity = simd_float2(0, -100)

        let (node, body) = makeBody(x: 0, y: 50, size: 10, dynamic: true)
        body.gravityScale = 0
        world.addBody(body)

        world.update(deltaTime: 0.1)

        XCTAssertEqual(body.velocity.y, 0)
        XCTAssertEqual(node.position.y, 50)
    }

    func testDynamicIsPushedOutOfStaticAlongShortestAxis() {
        let world = PhysicsWorld()

        // Static wall centered at x=100; dynamic body overlapping its
        // left edge by 10px (centers 90 apart, half-width sum 100).
        let (_, wall) = makeBody(x: 100, y: 0, size: 100, dynamic: false)
        let (mover, body) = makeBody(x: 10, y: 0, size: 100, dynamic: true)
        body.velocity = simd_float2(50, 0)   // Moving INTO the wall.
        world.addBody(wall)
        world.addBody(body)

        world.update(deltaTime: 0.001)

        // Pushed back out so the boxes only touch, and the into-wall
        // velocity component is killed.
        XCTAssertEqual(mover.position.x, 0, accuracy: 0.5)
        XCTAssertEqual(body.velocity.x, 0)
    }

    func testTriggerFiresSignalOnEnterOnly() {
        let world = PhysicsWorld()

        let trigger = CollisionNode()
        trigger.position = simd_float2(0, 0)
        trigger.triggerSignal = TestSupport.uniqueSignal("Entered")

        var fireCount = 0
        EventBus.shared.connect(to: trigger.triggerSignal) { fireCount += 1 }

        let (_, visitor) = makeBody(x: 10, y: 0, size: 50, dynamic: true)

        world.addBody(trigger.physicsBody!)
        world.addBody(visitor)

        world.update(deltaTime: 0.01)   // Overlap begins → ENTER fires.
        world.update(deltaTime: 0.01)   // Still overlapping → no re-fire.
        world.update(deltaTime: 0.01)

        XCTAssertEqual(fireCount, 1, "Trigger must fire exactly once per overlap enter")
    }

    func testLayerMaskFilteringSkipsNonMatchingPairs() {
        let world = PhysicsWorld()

        let (_, wall) = makeBody(x: 0, y: 0, size: 100, dynamic: false)
        wall.collisionLayer = 2
        wall.collisionMask = 2

        let (ghost, body) = makeBody(x: 10, y: 0, size: 100, dynamic: true)
        body.collisionLayer = 4
        body.collisionMask = 4   // Doesn't scan layer 2, and vice versa.

        world.addBody(wall)
        world.addBody(body)

        world.update(deltaTime: 0.01)

        // No resolution happened — the ghost stayed exactly put.
        XCTAssertEqual(ghost.position.x, 10)
    }

    func testRemoveBodiesOwnedBySubtree() {
        let world = PhysicsWorld()

        let parent = Node()
        let parentBody = PhysicsBody(size: simd_float2(10, 10))
        parent.addPhysicsBody(parentBody)

        let child = Node()
        let childBody = PhysicsBody(size: simd_float2(10, 10))
        child.addPhysicsBody(childBody)
        parent.addChild(child)

        world.addBody(parentBody)
        world.addBody(childBody)
        XCTAssertEqual(world.bodies.count, 2)

        world.removeBodies(ownedBy: parent)
        XCTAssertEqual(world.bodies.count, 0)
    }
}
