//
//  SerializationTests.swift
//  EngineTests
//
//  Scene JSON round-trips: every node type, physics bodies, behaviors,
//  rules, textures-by-name, and prefabs must survive
//  serialize → deserialize unchanged.
//

import XCTest
import simd
@testable import IngotEngineCore

final class SerializationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestSupport.openTempProject()
    }

    /// Serializes a scene and rebuilds it, returning the new root.
    private func roundTrip(_ scene: Scene) -> Node? {
        let json = SceneSerializer.serialize(scene)
        return SceneDeserializer.deserialize(jsonString: json)
    }

    func testWorldGravityRoundTripAndEngineApplication() {
        let scene = Scene()
        scene.gravity = simd_float2(0, -980)
        let json = SceneSerializer.serialize(scene)

        // Gravity survives the file round trip…
        let restored = Scene()
        restored.rootNode = SceneDeserializer.deserialize(jsonString: json)!
        SceneDeserializer.restoreWorldSettings(scene: restored, fromJSON: json)
        XCTAssertEqual(restored.gravity.y, -980)

        // …and reaches the physics world when the scene becomes current.
        let engine = Engine()
        engine.currentScene = restored
        XCTAssertEqual(engine.physicsWorld.gravity.y, -980)

        // Swapping to a default scene resets gravity to zero.
        engine.currentScene = Scene()
        XCTAssertEqual(engine.physicsWorld.gravity.y, 0)
    }

    func testTransformAndIdentityRoundTrip() {
        let scene = Scene()
        let node = Node()
        node.name = "Hero"
        node.position = simd_float2(12.5, -3)
        node.rotation = 1.25
        node.scale = simd_float2(2, 0.5)
        node.zIndex = 7
        node.isEnabled = false
        node.groups = ["enemies", "bosses"]
        scene.rootNode.addChild(node)

        let root = roundTrip(scene)
        let restored = root?.findChild(named: "Hero")

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.position.x, 12.5)
        XCTAssertEqual(restored?.position.y, -3)
        XCTAssertEqual(restored?.rotation ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertEqual(restored?.scale.x, 2)
        XCTAssertEqual(restored?.zIndex, 7)
        XCTAssertEqual(restored?.isEnabled, false)
        XCTAssertEqual(restored?.groups, ["enemies", "bosses"])
    }

    func testSpriteTextureNameAndAnimationRoundTrip() {
        let scene = Scene()
        let sprite = SpriteNode()
        sprite.name = "Player"
        sprite.textureName = "hero.png"
        sprite.defaultAnimationName = "idle"
        sprite.modulate = simd_float4(1, 0.5, 0.25, 0.75)
        scene.rootNode.addChild(sprite)

        let restored = roundTrip(scene)?.findChild(named: "Player") as? SpriteNode
        XCTAssertEqual(restored?.textureName, "hero.png")
        XCTAssertEqual(restored?.defaultAnimationName, "idle")
        XCTAssertEqual(restored?.modulate.y ?? 0, 0.5, accuracy: 0.0001)
    }

    func testPhysicsBodyRoundTrip() {
        let scene = Scene()
        let node = Node()
        node.name = "Crate"
        let body = PhysicsBody(size: simd_float2(64, 32), isDynamic: true)
        body.gravityScale = 0.5
        body.collisionLayer = 4
        body.collisionMask = 12
        node.addPhysicsBody(body)
        scene.rootNode.addChild(node)

        let restored = roundTrip(scene)?.findChild(named: "Crate")
        XCTAssertEqual(restored?.physicsBody?.size.x, 64)
        XCTAssertEqual(restored?.physicsBody?.isDynamic, true)
        XCTAssertEqual(restored?.physicsBody?.gravityScale ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(restored?.physicsBody?.collisionLayer, 4)
        XCTAssertEqual(restored?.physicsBody?.collisionMask, 12)
    }

    func testRuleRoundTripAllActionKinds() {
        let scene = Scene()
        let node = Node()
        node.name = "Ruley"
        node.addBehavior(Behavior(rules: [
            Rule(event: .onActionJustPressed("action"), actions: [
                .setVelocity(x: 0, y: 600),
                .playAnimation("jump"),
                .spawnPrefab("Dust", x: 1, y: 2),
                .changeScene("Level2"),
            ]),
            Rule(event: .onSignal("Timeout"), actions: [.destroy]),
        ]))
        scene.rootNode.addChild(node)

        let restored = roundTrip(scene)?.findChild(named: "Ruley")
        let rules = restored?.behaviors.first?.rules

        XCTAssertEqual(rules?.count, 2)
        XCTAssertEqual(rules?[0].event, .onActionJustPressed("action"))
        XCTAssertEqual(rules?[0].actions.count, 4)
        XCTAssertEqual(rules?[1].event, .onSignal("Timeout"))

        if case .playAnimation(let clip)? = rules?[0].actions[1] {
            XCTAssertEqual(clip, "jump")
        } else {
            XCTFail("playAnimation action lost in round trip")
        }
    }

    func testTileMapRoundTrip() {
        let scene = Scene()
        let map = TileMapNode()
        map.name = "Level"
        map.tileWidth = 32
        map.tileHeight = 48
        map.atlasColumns = 8
        map.atlasRows = 4
        map.solidTiles = [0, 5]
        map.fillRect(x: 0, y: 0, width: 3, height: 2, tileIndex: 5)
        scene.rootNode.addChild(map)

        let restored = roundTrip(scene)?.findChild(named: "Level") as? TileMapNode
        XCTAssertEqual(restored?.tiles.count, 6)
        XCTAssertEqual(restored?.tile(x: 2, y: 1), 5)
        XCTAssertEqual(restored?.tileWidth, 32)
        XCTAssertEqual(restored?.atlasColumns, 8)
        XCTAssertEqual(restored?.solidTiles, [0, 5])
        // Solid tiles must regenerate their colliders on load.
        XCTAssertEqual(restored?.collisionBodies.count, 6)
    }

    func testPrefabSaveAndInstantiate() {
        let enemy = SpriteNode()
        enemy.name = "Enemy"
        enemy.textureName = "enemy.png"
        let eye = Node()
        eye.name = "Eye"
        enemy.addChild(eye)

        XCTAssertTrue(PrefabLibrary.save(enemy, named: "TestEnemy"))
        XCTAssertTrue(PrefabLibrary.list().contains("TestEnemy"))

        let copy = PrefabLibrary.instantiate(named: "TestEnemy") as? SpriteNode
        XCTAssertNotNil(copy)
        XCTAssertEqual(copy?.textureName, "enemy.png")
        XCTAssertNotNil(copy?.findChild(named: "Eye"))
        // A prefab instance is a fresh object graph, never a shared one.
        XCTAssertFalse(copy === enemy)
    }
}
