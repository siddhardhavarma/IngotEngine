//
//  TimerNode.swift
//  IngotEngine
//
//  §4.4 Scene System — A countdown timer that emits a signal.
//
//  Modeled after Godot's Timer node. When the wait time elapses, the
//  timer emits `timeoutSignal` on the EventBus, so any behavior rule
//  with an onSignal event (or EventBus listener) can react to it.
//
//  Uses: enemy spawn waves, powerup expiry, cutscene pacing, cooldowns.
//

import Foundation

class TimerNode: Node {

    /// Seconds between timeouts.
    var waitTime: Float = 1.0

    /// If true, the timer stops after firing once. If false, it repeats.
    var oneShot: Bool = false

    /// If true, the timer starts counting as soon as the scene plays.
    var autostart: Bool = true

    /// The EventBus signal emitted on each timeout.
    var timeoutSignal: String = "Timeout"

    private(set) var isRunning = false
    private var elapsed: Float = 0

    override init() {
        super.init()
        name = "Timer"
    }

    /// Starts (or restarts) the countdown.
    func start() {
        elapsed = 0
        isRunning = true
    }

    /// Stops the countdown without firing.
    func stop() {
        isRunning = false
    }

    override func ready() {
        super.ready()
        if autostart {
            start()
        }
    }

    override func update(deltaTime: CFTimeInterval, input: InputManager) {
        guard isEnabled else { return }
        super.update(deltaTime: deltaTime, input: input)

        guard isRunning else { return }

        elapsed += Float(deltaTime)
        if elapsed >= waitTime {
            EventBus.shared.emit(timeoutSignal)
            if oneShot {
                isRunning = false
            } else {
                elapsed -= waitTime
            }
        }
    }
}
