//
//  FrameAnimation.swift
//  IngotEngine
//
//  §4.10 Animation System — Sprite frame animation.
//
//  Cycles through sprite sheet frames at a configurable FPS.
//  Attach to a SpriteNode to animate it without writing JS.
//
//  Usage:
//    let anim = FrameAnimation(gridWidth: 4, gridHeight: 2,
//                               startFrame: 0, endFrame: 7,
//                               fps: 12, loops: true)
//    playerNode.addBehavior(AnimationBehavior(animation: anim))
//

import Foundation

/// Defines a sequence of frames within a sprite sheet grid.
struct FrameAnimation {

    /// Number of columns in the sprite sheet grid.
    let gridWidth: Int

    /// Number of rows in the sprite sheet grid.
    let gridHeight: Int

    /// First frame index (0-based, left-to-right, top-to-bottom).
    let startFrame: Int

    /// Last frame index (inclusive).
    let endFrame: Int

    /// Playback speed in frames per second.
    var fps: Float

    /// Whether the animation loops back to startFrame after endFrame.
    var loops: Bool

    /// Total number of frames in this animation.
    var frameCount: Int { endFrame - startFrame + 1 }

    /// Converts a linear frame index to (column, row) in the grid.
    func gridPosition(for frame: Int) -> (column: Int, row: Int) {
        let clamped = startFrame + (frame % frameCount)
        return (clamped % gridWidth, clamped / gridWidth)
    }
}

/// A Behavior that drives sprite sheet animation on the owner node.
class AnimationBehavior: Behavior {

    var animation: FrameAnimation

    private var elapsedTime: Float = 0
    private var currentFrame: Int = 0
    private var finished = false

    init(animation: FrameAnimation) {
        self.animation = animation
        super.init(rules: [])
    }

    override func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard let owner = owner as? SpriteNode, !finished else { return }

        let dt = Float(deltaTime)
        elapsedTime += dt

        // Compute which frame we should be on based on elapsed time.
        let rawFrame = Int(elapsedTime * animation.fps)

        if animation.loops {
            currentFrame = rawFrame % animation.frameCount
        } else {
            currentFrame = min(rawFrame, animation.frameCount - 1)
            if rawFrame >= animation.frameCount {
                finished = true
            }
        }

        let (col, row) = animation.gridPosition(for: currentFrame)
        owner.setSpriteSheetFrame(gridWidth: animation.gridWidth,
                                   gridHeight: animation.gridHeight,
                                   column: col, row: row)
    }

    /// Resets the animation to the first frame.
    func reset() {
        elapsedTime = 0
        currentFrame = 0
        finished = false
    }
}
