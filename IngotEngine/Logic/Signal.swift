//
//  Signal.swift
//  IngotEngine
//
//  A lightweight observer pattern. A Signal holds a list of listener
//  closures and calls them all when emitted. This is the building block
//  for the EventBus — each named event owns one Signal.
//

import Foundation

class Signal {

    /// The registered listener closures, called in order when emit() fires.
    private var listeners: [() -> Void] = []

    /// Registers a closure that will be called every time this signal emits.
    func connect(_ closure: @escaping () -> Void) {
        listeners.append(closure)
    }

    /// Fires the signal, calling all connected listeners in registration order.
    func emit() {
        for listener in listeners {
            listener()
        }
    }
}
