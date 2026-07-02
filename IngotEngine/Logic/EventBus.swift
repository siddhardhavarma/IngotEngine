//
//  EventBus.swift
//  IngotEngine
//
//  A global publish-subscribe messaging system for decoupled communication.
//
//  WHY A DECOUPLED EVENT BUS?
//
//  In a game engine, many systems need to react to things that happen:
//
//    - The player presses spacebar → the UI should show a "jump" animation
//    - An enemy dies → the score counter increments
//    - A power-up is collected → a sound plays AND particles spawn
//
//  Without an EventBus, these systems would need direct references to each
//  other: the player node would need to know about the UI, the enemy about
//  the score system, the power-up about both sound and particles. The code
//  becomes a web of dependencies.
//
//  With an EventBus, the player just emits "PlayerJumped" and walks away.
//  Any number of listeners can independently react — the player doesn't
//  know or care who's listening. New systems can subscribe without
//  modifying the emitter.
//
//  This is especially important when separating game logic from UI:
//
//    Game logic:   EventBus.shared.emit("ScoreChanged")
//    UI layer:     EventBus.shared.connect(to: "ScoreChanged") { updateLabel() }
//
//  The game logic never imports the UI framework. The UI layer never
//  reaches into game objects. They communicate through named events.
//  This means you can swap out the entire UI (say, from AppKit to SwiftUI)
//  without touching a single line of game code.
//

import Foundation

class EventBus {

    /// The global singleton. Accessible from anywhere in the engine.
    static let shared = EventBus()

    /// Maps event names to their Signal objects. Created lazily on first connect.
    private var signals: [String: Signal] = [:]

    private init() {}

    /// Registers a listener closure for the given event name.
    /// If no signal exists yet for that name, one is created automatically.
    func connect(to eventName: String, _ closure: @escaping () -> Void) {
        if signals[eventName] == nil {
            signals[eventName] = Signal()
        }
        signals[eventName]!.connect(closure)
    }

    /// Emits the named event, calling all connected listeners.
    /// If no one has connected to this event, this is a silent no-op.
    func emit(_ eventName: String) {
        signals[eventName]?.emit()
    }
}
