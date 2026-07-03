//
//  BehaviorTests.swift
//  EngineTests
//
//  The event-action rule system, input edges, timers, and signals —
//  the decoupling backbone that AI-generated logic relies on.
//

import XCTest
import simd
@testable import IngotEngineCore

final class BehaviorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InputManager.shared.clearAllActions()
    }

    func testOnActionHeldMovesOwnerEveryFrame() {
        let node = Node()
        let behavior = Behavior(rules: [
            Rule(event: .onActionHeld("test_right"), actions: [.move(x: 100, y: 0)])
        ])
        node.addBehavior(behavior)

        InputManager.shared.setActionPressed("test_right", isPressed: true)
        behavior.update(deltaTime: 0.5, input: .shared)
        behavior.update(deltaTime: 0.5, input: .shared)

        XCTAssertEqual(node.position.x, 100, accuracy: 0.001)
    }

    func testJustPressedIsAnEdgeNotALevel() {
        let input = InputManager.shared

        input.setActionPressed("test_jump", isPressed: true)
        XCTAssertTrue(input.isActionJustPressed("test_jump"))

        input.endFrame()   // The engine clears edges at end of frame.
        XCTAssertTrue(input.isActionPressed("test_jump"), "Still held")
        XCTAssertFalse(input.isActionJustPressed("test_jump"), "Edge consumed")

        // Holding does not re-arm the edge; releasing and pressing does.
        input.setActionPressed("test_jump", isPressed: true)
        XCTAssertFalse(input.isActionJustPressed("test_jump"))
        input.setActionPressed("test_jump", isPressed: false)
        input.setActionPressed("test_jump", isPressed: true)
        XCTAssertTrue(input.isActionJustPressed("test_jump"))
    }

    func testOnStartFiresExactlyOnce() {
        let node = Node()
        let signal = TestSupport.uniqueSignal("Started")
        var count = 0
        EventBus.shared.connect(to: signal) { count += 1 }

        let behavior = Behavior(rules: [
            Rule(event: .onStart, actions: [.emitSignal(signal)])
        ])
        node.addBehavior(behavior)

        behavior.update(deltaTime: 0.016, input: .shared)
        behavior.update(deltaTime: 0.016, input: .shared)
        behavior.update(deltaTime: 0.016, input: .shared)

        XCTAssertEqual(count, 1)
    }

    func testOnSignalRuleFiresWhenSignalEmitted() {
        let node = Node()
        let signal = TestSupport.uniqueSignal("Poke")

        let behavior = Behavior(rules: [
            Rule(event: .onSignal(signal), actions: [.setProperty("positionX", 42)])
        ])
        node.addBehavior(behavior)

        // start() wires the EventBus subscription (Node.update does
        // this in the real loop).
        behavior.start()

        behavior.update(deltaTime: 0.016, input: .shared)
        XCTAssertEqual(node.position.x, 0, "No signal yet — rule must not fire")

        EventBus.shared.emit(signal)
        behavior.update(deltaTime: 0.016, input: .shared)
        XCTAssertEqual(node.position.x, 42)

        behavior.update(deltaTime: 0.016, input: .shared)
        XCTAssertEqual(node.position.x, 42, "Signal is consumed, not sticky")
    }

    func testTimerNodeEmitsOnTimeoutAndRepeats() {
        let timer = TimerNode()
        timer.waitTime = 1.0
        timer.autostart = true
        timer.oneShot = false
        timer.timeoutSignal = TestSupport.uniqueSignal("Tick")

        var ticks = 0
        EventBus.shared.connect(to: timer.timeoutSignal) { ticks += 1 }

        // First update fires ready() (autostart), then time accumulates.
        timer.update(deltaTime: 0.6, input: .shared)
        XCTAssertEqual(ticks, 0)
        timer.update(deltaTime: 0.6, input: .shared)
        XCTAssertEqual(ticks, 1)
        timer.update(deltaTime: 1.0, input: .shared)
        XCTAssertEqual(ticks, 2, "Repeating timer keeps firing")
    }

    func testDestroyActionRemovesNodeAndUnregistersBody() {
        let world = PhysicsWorld()
        PhysicsWorld.current = world

        let parent = Node()
        let doomed = Node()
        let body = PhysicsBody(size: simd_float2(10, 10))
        doomed.addPhysicsBody(body)
        parent.addChild(doomed)
        world.addBody(body)

        let behavior = Behavior(rules: [
            Rule(event: .everyFrame, actions: [.destroy])
        ])
        doomed.addBehavior(behavior)
        behavior.update(deltaTime: 0.016, input: .shared)

        XCTAssertTrue(parent.children.isEmpty, "Node removed from tree")
        XCTAssertTrue(world.bodies.isEmpty, "Body unregistered — no ghost collisions at origin")
    }
}
