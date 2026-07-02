//
//  InputManager.swift
//  IngotEngine
//
//  Platform-agnostic input abstraction. Maps hardware-specific inputs
//  (keycodes, touch zones, gamepad buttons) to named string actions.
//
//  HOW STRING-BASED ACTIONS ENABLE CROSS-PLATFORM SCRIPTS:
//
//  The user's game script checks:
//    if (Input.isActionPressed("move_left")) { node.x -= 200 * dt; }
//
//  On macOS, keyCode 123 (←) sets actionStates["move_left"] = true.
//  On iOS, a virtual joystick thumb moving left would call:
//    InputManager.shared.setActionPressed("move_left", isPressed: true)
//
//  The script is identical on both platforms — it only speaks in
//  action names ("move_left"), never in keycodes (123) or touch
//  coordinates. Adding a new input device (gamepad, Apple TV remote)
//  just means mapping its hardware events to the same action strings.
//

import Foundation
import JavaScriptCore

// ---------------------------------------------------------------------------
// JSExport protocol — exposes InputManager to JavaScript
// ---------------------------------------------------------------------------
@objc protocol InputJSExport: JSExport {
    /// JS usage: Input.isActionPressed("move_left")
    func isActionPressed(_ action: String) -> Bool

    /// JS usage: Input.isActionJustPressed("action") — true only on the
    /// first frame the action goes down (Godot's is_action_just_pressed).
    func isActionJustPressed(_ action: String) -> Bool
}

// ---------------------------------------------------------------------------
// InputManager
// ---------------------------------------------------------------------------
/// Inherits from NSObject for JavaScriptCore compatibility.
class InputManager: NSObject, InputJSExport {

    /// Global singleton — accessible from Engine, Viewport, and JS scripts.
    static let shared = InputManager()

    /// Current state of each named action (true = pressed this frame).
    private var actionStates: [String: Bool] = [:]

    /// Actions that transitioned from released → pressed since the last
    /// endFrame(). Cleared by the Engine at the end of each step.
    private var justPressedActions: Set<String> = []

    /// Maps hardware keycodes to action name strings.
    /// Multiple keys can map to the same action (e.g., both A and ← → "move_left").
    /// This dictionary is user-configurable — a settings UI could let the
    /// player rebind keys by editing this map.
    var inputMap: [UInt16: String] = [
        // Arrow keys
        123: "move_left",     // ←
        124: "move_right",    // →
        126: "move_up",       // ↑ / jump
        125: "move_down",     // ↓

        // WASD
        0:   "move_left",     // A
        2:   "move_right",    // D
        13:  "move_up",       // W
        1:   "move_down",     // S

        // Actions
        49:  "action",        // Spacebar
    ]

    private override init() {
        super.init()
    }

    // MARK: - Hardware input (called by the platform layer)

    /// Called by ViewportViewController when a key is pressed or released.
    /// Looks up the keycode in the input map and updates the action state.
    func setKeyPressed(_ keyCode: UInt16, isPressed: Bool) {
        guard let action = inputMap[keyCode] else { return }
        setActionPressed(action, isPressed: isPressed)
    }

    /// Directly set an action state by name. Used by virtual joysticks,
    /// gamepad adapters, or AI-driven input injection.
    func setActionPressed(_ action: String, isPressed: Bool) {
        if isPressed && !(actionStates[action] ?? false) {
            justPressedActions.insert(action)
        }
        actionStates[action] = isPressed
    }

    // MARK: - Game-side queries (called by Behaviors and JS scripts)

    /// Returns true if the named action is currently active.
    /// Called from both Swift (Behavior rules) and JavaScript (Input.isActionPressed).
    @objc func isActionPressed(_ action: String) -> Bool {
        return actionStates[action] ?? false
    }

    /// Returns true only on the frame the action first went down.
    @objc func isActionJustPressed(_ action: String) -> Bool {
        return justPressedActions.contains(action)
    }

    /// Clears the per-frame "just pressed" edges. The Engine calls this
    /// at the end of each step.
    func endFrame() {
        justPressedActions.removeAll()
    }

    /// Clears all action states. Called when the engine stops playing
    /// so stale key states don't persist into the next play session.
    func clearAllActions() {
        actionStates.removeAll()
        justPressedActions.removeAll()
    }
}
