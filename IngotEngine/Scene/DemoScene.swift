//
//  DemoScene.swift
//  IngotEngine
//
//  A demo scene with a player, walls, and a camera that follows the player.
//

import MetalKit
import simd

class DemoScene: Scene {

    var playerNode: SpriteNode!
    var cameraNode: CameraNode!

    func setup(texture: MTLTexture) {

        // --- Player ---
        playerNode = SpriteNode()
        playerNode.name = "Player"
        playerNode.texture = texture
        playerNode.position = simd_float2(400, 300)
        playerNode.setSpriteSheetFrame(gridWidth: 2, gridHeight: 2, column: 0, row: 0)

        let playerBody = PhysicsBody(size: simd_float2(50, 50), isDynamic: true)
        playerNode.addPhysicsBody(playerBody)

        let speed: Float = 300.0
        let movementBehavior = Behavior(rules: [
            Rule(event: .onActionHeld("move_left"),  actions: [.move(x: -speed, y: 0)]),
            Rule(event: .onActionHeld("move_right"), actions: [.move(x:  speed, y: 0)]),
            Rule(event: .onActionHeld("move_up"),    actions: [.move(x: 0, y:  speed)]),
            Rule(event: .onActionHeld("move_down"),  actions: [.move(x: 0, y: -speed)]),
            Rule(event: .onActionHeld("action"),     actions: [.emitSignal("PlayerJumped")]),
        ])
        playerNode.addBehavior(movementBehavior)

        // Animation script.
        let animCode = """
        var Script = {
            start: function(node) {},
            update: function(node, dt, time) {
                var fps = 4, cols = 2, rows = 2;
                var frame = Math.floor(time * fps) % (cols * rows);
                node.setFrame(cols, rows, frame % cols, Math.floor(frame / cols));
            }
        };
        """
        ProjectManager.shared.createScriptFile(named: "PlayerAnimator.js", code: animCode)
        playerNode.addBehavior(ScriptBehavior(scriptName: "PlayerAnimator.js"))

        rootNode.addChild(playerNode)

        // --- Camera (child of player → follows automatically) ---
        cameraNode = CameraNode()
        cameraNode.name = "Camera"
        cameraNode.zoom = 1.0
        // Local position (0, 0) relative to player = centered on player.
        playerNode.addChild(cameraNode)
        activeCamera = cameraNode

        // --- Scatter walls so the camera effect is visible ---
        let wallPositions: [simd_float2] = [
            simd_float2(200, 300),
            simd_float2(700, 300),
            simd_float2(450, 550),
            simd_float2(100, 100),
            simd_float2(800, 500),
        ]

        for (i, pos) in wallPositions.enumerated() {
            let wall = SpriteNode()
            wall.name = "Wall_\(i)"
            wall.texture = texture
            wall.position = pos

            let body = PhysicsBody(size: simd_float2(100, 100), isDynamic: false)
            wall.addPhysicsBody(body)
            rootNode.addChild(wall)
        }

        // --- Event Bus ---
        EventBus.shared.connect(to: "Collision") {
            print("BAM! Collision detected!")
        }
    }
}
