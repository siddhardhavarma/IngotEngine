//
//  Node+JSExport.swift
//  IngotEngine
//
//  Bridges Node properties to JavaScriptCore so scripts can read and
//  modify nodes at runtime without recompiling Swift.
//
//  Available in JS:
//    node.x, node.y        — position (read/write)
//    node.rotationDegrees  — rotation in degrees (read/write)
//    node.scaleX, node.scaleY — scale (read/write)
//    node.zIndex           — draw order (read/write)
//    node.visible          — enabled/visible flag (read/write)
//    node.name             — node name (read-only)
//    node.jsZoom           — camera zoom (read/write, CameraNode only)
//    node.setFrame(gridW, gridH, col, row) — sprite sheet frame
//    node.getChild(name)   — find a descendant by name
//    node.emitSignal(name) — broadcast a signal on the EventBus
//    node.setVelocity(x,y) — set physics velocity (needs a PhysicsBody)
//    node.spawn(prefab, x, y) — instantiate a prefab under the scene root
//    node.destroy()        — remove the node from the scene
//

import JavaScriptCore
import simd

@objc protocol NodeJSExport: JSExport {
    var x: Float { get set }
    var y: Float { get set }
    var rotationDegrees: Float { get set }
    var scaleX: Float { get set }
    var scaleY: Float { get set }
    var zIndexJS: Int { get set }
    var visible: Bool { get set }
    var name: String { get }

    /// Camera zoom. No-op on plain Nodes; CameraNode overrides.
    var jsZoom: Float { get set }

    /// Sets the sprite sheet frame. No-op on plain Nodes; SpriteNode overrides.
    func setFrame(_ gridWidth: Int, _ gridHeight: Int, _ column: Int, _ row: Int)

    func getChild(_ name: String) -> Node?
    func emitSignal(_ name: String)
    func setVelocity(_ x: Float, _ y: Float)
    func spawn(_ prefabName: String, _ x: Float, _ y: Float) -> Node?
    func changeScene(_ name: String)
    func destroy()
}

extension Node: NodeJSExport {

    @objc var x: Float {
        get { position.x }
        set { position.x = newValue }
    }

    @objc var y: Float {
        get { position.y }
        set { position.y = newValue }
    }

    @objc var rotationDegrees: Float {
        get { rotation * 180 / .pi }
        set { rotation = newValue * .pi / 180 }
    }

    @objc var scaleX: Float {
        get { scale.x }
        set { scale.x = newValue }
    }

    @objc var scaleY: Float {
        get { scale.y }
        set { scale.y = newValue }
    }

    // "zIndex" clashes with the stored Swift property name, so the
    // ObjC-visible selector is zIndexJS; JS still reads node.zIndexJS.
    @objc var zIndexJS: Int {
        get { zIndex }
        set { zIndex = newValue }
    }

    @objc var visible: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }

    /// Base implementation — no-op for plain Nodes.
    @objc var jsZoom: Float {
        get { 1.0 }
        set { /* no-op: plain Nodes don't have zoom */ }
    }

    /// Base implementation — no-op for plain Nodes.
    @objc func setFrame(_ gridWidth: Int, _ gridHeight: Int, _ column: Int, _ row: Int) {
        // No-op: plain Nodes don't have a UV rect.
    }

    @objc func getChild(_ name: String) -> Node? {
        findChild(named: name)
    }

    @objc func emitSignal(_ name: String) {
        EventBus.shared.emit(name)
    }

    @objc func setVelocity(_ x: Float, _ y: Float) {
        physicsBody?.velocity = simd_float2(x, y)
    }

    @objc func spawn(_ prefabName: String, _ x: Float, _ y: Float) -> Node? {
        guard let instance = PrefabLibrary.instantiate(named: prefabName) else { return nil }
        instance.position = simd_float2(x, y)
        sceneRoot.addChild(instance)
        if let world = PhysicsWorld.current {
            if let body = instance.physicsBody { world.addBody(body) }
            for child in instance.allDescendants() {
                if let body = child.physicsBody { world.addBody(body) }
            }
        }
        return instance
    }

    /// Requests a scene change at the end of this frame.
    /// JS: node.changeScene("Level2")
    @objc func changeScene(_ name: String) {
        Engine.current?.requestScene(named: name)
    }

    @objc func destroy() {
        PhysicsWorld.current?.removeBodies(ownedBy: self)
        removeFromParent()
    }
}
