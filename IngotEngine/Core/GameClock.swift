//
//  GameClock.swift
//  IngotEngine
//
//  §4.2 Core/Foundation — Time management.
//
//  Tracks per-frame timing, total elapsed time, and provides a
//  fixed-step accumulator for deterministic physics (§4.7).
//  The Engine reads from this each frame; nothing else touches it.
//

import Foundation
import QuartzCore

class GameClock {

    /// Seconds elapsed since the last frame. Clamped to avoid huge
    /// jumps when the app is paused or the debugger attaches.
    private(set) var deltaTime: Float = 0

    /// Total seconds elapsed since the clock started (or was reset).
    private(set) var totalTime: Float = 0

    /// The raw timestamp of the previous frame (CACurrentMediaTime).
    private var lastFrameTimestamp: CFTimeInterval = 0

    /// Maximum allowed deltaTime. Anything above this is clamped
    /// to prevent physics explosions after a long pause.
    var maxDeltaTime: Float = 0.05

    /// Accumulated time for fixed-step physics updates.
    /// The physics loop drains this in fixed increments.
    private(set) var fixedAccumulator: Float = 0

    /// The fixed time step for deterministic physics (1/60 by default).
    var fixedTimeStep: Float = 1.0 / 60.0

    /// Call once at the start to initialize the timestamp.
    func start() {
        lastFrameTimestamp = CACurrentMediaTime()
        deltaTime = 0
        totalTime = 0
        fixedAccumulator = 0
    }

    /// Call at the top of each frame. Computes deltaTime and
    /// accumulates time for the fixed physics step.
    ///
    /// - Parameter timeScale: Engine's time scale multiplier (1.0 = normal).
    func tick(timeScale: Float) {
        let now = CACurrentMediaTime()
        var rawDelta = Float(now - lastFrameTimestamp)
        lastFrameTimestamp = now

        // Clamp to prevent spiral-of-death after pauses.
        if rawDelta > maxDeltaTime {
            rawDelta = 1.0 / 60.0
        }

        deltaTime = rawDelta * timeScale
        totalTime += deltaTime
        fixedAccumulator += deltaTime
    }

    /// Drains one fixed time step from the accumulator.
    /// Returns true if a step was consumed (caller should run physics).
    func consumeFixedStep() -> Bool {
        if fixedAccumulator >= fixedTimeStep {
            fixedAccumulator -= fixedTimeStep
            return true
        }
        return false
    }

    /// Resets all timing state. Called when stopping play mode.
    func reset() {
        deltaTime = 0
        totalTime = 0
        fixedAccumulator = 0
        lastFrameTimestamp = CACurrentMediaTime()
    }
}
