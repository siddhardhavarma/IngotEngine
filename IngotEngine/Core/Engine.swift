//
//  Engine.swift
//  IngotEngine
//
//  §4.11 Engine Orchestrator — The conductor of the game loop.
//
//  Owns the game clock, all subsystems, and the current scene.
//  Calls every system in the correct order each frame (§8):
//
//    time → input → behavior → scene update → physics
//           → animation → camera → (render) → audio
//
//  The renderer (ViewportViewController) is NOT part of the engine.
//  It calls engine.step(), then reads the scene tree to draw.
//  This separation enables headless mode (§4.11): the engine can
//  run without any GPU, window, or display — critical for unit
//  tests, CI pipelines, and server-side simulation.
//
//  Imports Foundation only — no Metal, no AppKit, no UIKit.
//

import Foundation

class Engine {

    // MARK: - Subsystems (§4.x)

    /// §4.2 — Frame timing, deltaTime, totalTime, fixed-step accumulator.
    let clock = GameClock()

    /// §4.7 — AABB collision detection and resolution.
    let physicsWorld = PhysicsWorld()

    /// §4.9 — Sound effect playback.
    let audio = AudioManager()

    /// §4.9 — Background music streaming.
    let music = MusicPlayer()

    /// §4.10 — Global tween manager for property animations.
    let tweens = TweenManager()

    // MARK: - Scene (§4.4)

    /// The scene currently being simulated. When set, physics bodies
    /// are re-registered and the clock resets.
    var currentScene: Scene? {
        didSet {
            physicsWorld.removeAllBodies()
            currentScene?.registerPhysicsBodies(with: physicsWorld)
        }
    }

    // MARK: - Play State

    /// When false, step() skips logic — the editor is in design mode.
    /// When true, the full game loop runs each frame.
    var isPlaying: Bool = false {
        didSet {
            if isPlaying {
                clock.start()
            } else {
                InputManager.shared.clearAllActions()
                clock.reset()
            }
        }
    }

    /// Time scale multiplier. 1.0 = normal, 0.5 = slow-mo, 2.0 = fast-forward.
    var timeScale: Float = 1.0

    // MARK: - Initialization

    init() {
        EventBus.shared.connect(to: "Collision") { [weak self] in
            self?.audio.playSound(named: "bump.wav")
        }
    }

    // MARK: - Game Loop (§8 execution order)

    /// Advances the simulation by one frame.
    ///
    /// Called by the renderer's MTKView callback. The renderer passes
    /// its raw deltaTime; the engine applies timeScale and clamps.
    ///
    /// Execution order matches §8 of the blueprint:
    ///   1. Time    — compute deltaTime via GameClock
    ///   2. Input   — already polled by the platform layer (InputManager)
    ///   3. Behavior + Scene update — cascades Node.update → behaviors → scripts
    ///   4. Physics — collision detection on updated positions
    ///   5. Animation — (future: advance frame animations and tweens)
    ///   6. Camera  — (handled by the renderer reading activeCamera)
    ///   7. Render  — (handled by ViewportViewController, not the engine)
    ///   8. Audio   — (serviced by OS audio thread, no per-frame work needed)
    func step(deltaTime: Float) {
        guard isPlaying else { return }

        // 1. Time — tick the clock with the engine's time scale.
        clock.tick(timeScale: timeScale)
        let dt = CFTimeInterval(clock.deltaTime)

        // 2. Input — InputManager.shared is already updated by the
        //    platform layer (ViewportViewController.keyDown/keyUp).
        //    No explicit poll step needed on macOS.

        // 3. Behavior + Scene update — behaviors read input, move nodes,
        //    run scripts. This cascades through the entire node tree.
        currentScene?.update(deltaTime: dt, input: InputManager.shared)

        // 4. Physics — detect and resolve collisions on the new positions.
        //    Uses fixed time step for deterministic results.
        while clock.consumeFixedStep() {
            physicsWorld.update(deltaTime: CFTimeInterval(clock.fixedTimeStep))
        }

        // 5. Animation — advance global tweens. (FrameAnimations run
        //    as behaviors in step 3, so they're already updated.)
        tweens.update(deltaTime: clock.deltaTime)

        // 6. Camera — (no engine work needed; the renderer reads
        //    currentScene.activeCamera each frame)

        // 7. Render — (handled externally by ViewportViewController)

        // 8. Audio — (AVAudioPlayer runs on the OS audio thread;
        //    no per-frame servicing needed)
    }
}
