//
//  PhysicsBody.swift
//  IngotEngine
//
//  An Axis-Aligned Bounding Box (AABB) physics body attached to a Node.
//
//  AABB means the collision rectangle is always aligned with the X and Y axes
//  — it never rotates. This makes overlap checks extremely fast (just 4
//  comparisons), which is why most 2D engines use AABB for broadphase
//  collision detection.
//

import CoreGraphics
import Foundation
import simd

class PhysicsBody {

    /// The node this body is attached to. Weak to avoid retain cycles.
    /// The body reads the node's globalTransform to find its world position.
    weak var owner: Node?

    /// The width and height of the bounding box in pixels.
    var size: simd_float2

    /// If true, this body moves (player, enemies, projectiles).
    /// If false, it's a static obstacle (walls, floors, platforms).
    /// The physics world can use this to skip static-vs-static checks.
    var isDynamic: Bool

    /// Linear velocity in pixels/second, integrated by the PhysicsWorld
    /// each fixed step (Godot's CharacterBody2D.velocity). Behaviors and
    /// scripts set this; the world moves the owner and applies gravity.
    var velocity = simd_float2(0, 0)

    /// How strongly the world's gravity affects this body.
    /// 0 = ignores gravity (top-down movement), 1 = full gravity.
    var gravityScale: Float = 1.0

    /// If true, this body detects overlaps but never blocks movement
    /// (Godot's Area2D). CollisionNode sets this automatically.
    var isTrigger: Bool = false

    /// Which layers this body occupies / scans (Godot's collision_layer
    /// and collision_mask bitfields). Two bodies interact when either
    /// one's mask includes a layer the other occupies.
    var collisionLayer: UInt32 = 1
    var collisionMask: UInt32 = 0xFFFFFFFF

    /// World-axis offset of the box center from the owner's position.
    /// Used by TileMapNode to attach many tile colliders to one node.
    var offset = simd_float2(0, 0)

    init(size: simd_float2, isDynamic: Bool = true) {
        self.size = size
        self.isDynamic = isDynamic
    }

    /// The world-space bounding rectangle, computed from the owner's
    /// globalTransform, this body's offset, and its size.
    ///
    ///   globalTransform column 3:
    ///     [3][0] = world X
    ///     [3][1] = world Y
    ///
    ///   CGRect origin = center - halfSize  (bottom-left corner)
    var boundingBox: CGRect {
        guard let owner = owner else { return .zero }

        let transform = owner.globalTransform
        let centerX = CGFloat(transform.columns.3.x + offset.x)
        let centerY = CGFloat(transform.columns.3.y + offset.y)
        let halfW = CGFloat(size.x / 2)
        let halfH = CGFloat(size.y / 2)

        return CGRect(x: centerX - halfW,
                      y: centerY - halfH,
                      width: CGFloat(size.x),
                      height: CGFloat(size.y))
    }
}
