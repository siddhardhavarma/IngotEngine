//
//  Node+JSExport.swift
//  IngotEngine
//
//  Bridges Node properties to JavaScriptCore so scripts can read and
//  modify nodes at runtime without recompiling Swift.
//
//  Available in JS:
//    node.x          — position.x (read/write)
//    node.y          — position.y (read/write)
//    node.name       — node name (read-only)
//    node.jsZoom     — camera zoom (read/write, CameraNode only)
//    node.setFrame(gridW, gridH, col, row) — sprite sheet frame
//

import JavaScriptCore

@objc protocol NodeJSExport: JSExport {
    var x: Float { get set }
    var y: Float { get set }
    var name: String { get }

    /// Camera zoom. No-op on plain Nodes; CameraNode overrides.
    var jsZoom: Float { get set }

    /// Sets the sprite sheet frame. No-op on plain Nodes; SpriteNode overrides.
    func setFrame(_ gridWidth: Int, _ gridHeight: Int, _ column: Int, _ row: Int)
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

    /// Base implementation — no-op for plain Nodes.
    @objc var jsZoom: Float {
        get { 1.0 }
        set { /* no-op: plain Nodes don't have zoom */ }
    }

    /// Base implementation — no-op for plain Nodes.
    @objc func setFrame(_ gridWidth: Int, _ gridHeight: Int, _ column: Int, _ row: Int) {
        // No-op: plain Nodes don't have a UV rect.
    }
}
