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

    init(size: simd_float2, isDynamic: Bool = true) {
        self.size = size
        self.isDynamic = isDynamic
    }

    /// The world-space bounding rectangle, computed from the owner's
    /// globalTransform and this body's size.
    ///
    /// The globalTransform's column 3 contains the world-space position
    /// (translation). We extract X and Y from there and build a CGRect
    /// centered on that point.
    ///
    ///   globalTransform column 3:
    ///     [3][0] = world X
    ///     [3][1] = world Y
    ///
    ///   CGRect origin = center - halfSize  (bottom-left corner)
    var boundingBox: CGRect {
        guard let owner = owner else { return .zero }

        let transform = owner.globalTransform
        let centerX = CGFloat(transform.columns.3.x)
        let centerY = CGFloat(transform.columns.3.y)
        let halfW = CGFloat(size.x / 2)
        let halfH = CGFloat(size.y / 2)

        return CGRect(x: centerX - halfW,
                      y: centerY - halfH,
                      width: CGFloat(size.x),
                      height: CGFloat(size.y))
    }
}
